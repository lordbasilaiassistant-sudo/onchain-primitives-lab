// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title AtomicSwapHTLC
/// @notice Hash time-locked contract for trustless same-chain P2P swaps.
///         Maker locks asset A against keccak256(secret), names a taker, sets a
///         deadline. Taker matches by locking asset B against the same hash.
///         Anyone with the preimage can call claim() — it pays asset A to the
///         taker and asset B to the maker atomically. If the deadline passes
///         with no claim, each side can refund its own lock.
/// @dev    Atomicity: claim() releases BOTH legs in one tx using the same
///         preimage. Refund is gated strictly by `block.timestamp > deadline`,
///         so it cannot race a valid claim. Treasury fee is skimmed at claim
///         time from each leg and forwarded immediately — no claim() needed.
///         Treasury can lower the fee but never above the immutable cap.
contract AtomicSwapHTLC {
    enum Status {
        None,
        Open,        // maker locked, awaiting taker
        Matched,     // both sides locked, awaiting reveal
        Claimed,     // preimage revealed, paid out
        RefundedMaker,
        RefundedTaker,
        RefundedBoth
    }

    struct Swap {
        address maker;
        address taker;
        address tokenA;     // address(0) for native ETH
        address tokenB;     // address(0) for native ETH
        uint256 amountA;
        uint256 amountB;
        bytes32 hashlock;
        uint64 deadline;
        Status status;
        bool makerRefunded;
        bool takerRefunded;
    }

    Swap[] public swaps;
    mapping(address => uint256[]) private _byMaker;
    mapping(address => uint256[]) private _byTaker;

    address public treasury;
    uint16 public swapFeeBps;
    uint16 public immutable maxSwapFeeBps;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event OfferOpened(
        uint256 indexed swapId,
        address indexed maker,
        address indexed taker,
        address tokenA,
        uint256 amountA,
        bytes32 hashlock,
        uint64 deadline
    );
    event OfferMatched(
        uint256 indexed swapId,
        address indexed taker,
        address tokenB,
        uint256 amountB
    );
    event Claimed(
        uint256 indexed swapId,
        address indexed claimer,
        bytes32 preimage,
        uint256 toTaker,
        uint256 toMaker,
        uint256 feeA,
        uint256 feeB
    );
    event Refunded(uint256 indexed swapId, address indexed party, uint256 amount, bool isMaker);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 swapFeeBps);

    error NotTreasury();
    error ZeroAddress();
    error ZeroValue();
    error FeeAboveCap();
    error InvalidSwap();
    error NotOpen();
    error NotMatched();
    error NotTaker();
    error NotParticipant();
    error WrongValue();
    error WrongPreimage();
    error DeadlineNotPassed();
    error DeadlinePassed();
    error AlreadyRefunded();
    error TransferFailed();
    error SelfSwap();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury, uint16 _swapFeeBps, uint16 _maxSwapFeeBps) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxSwapFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_swapFeeBps > _maxSwapFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        swapFeeBps = _swapFeeBps;
        maxSwapFeeBps = _maxSwapFeeBps;
    }

    /// @notice Maker opens an offer: locks tokenA, names a taker, sets deadline.
    function openMaker(
        bytes32 hashlock,
        address taker,
        address tokenA,
        uint256 amountA,
        uint64 deadline_
    ) external payable returns (uint256 swapId) {
        if (taker == address(0)) revert ZeroAddress();
        if (taker == msg.sender) revert SelfSwap();
        if (amountA == 0) revert ZeroValue();
        if (hashlock == bytes32(0)) revert InvalidSwap();
        if (deadline_ <= block.timestamp) revert DeadlinePassed();

        if (tokenA == address(0)) {
            if (msg.value != amountA) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
        }

        swapId = swaps.length;
        swaps.push(Swap({
            maker: msg.sender,
            taker: taker,
            tokenA: tokenA,
            tokenB: address(0),
            amountA: amountA,
            amountB: 0,
            hashlock: hashlock,
            deadline: deadline_,
            status: Status.Open,
            makerRefunded: false,
            takerRefunded: false
        }));
        _byMaker[msg.sender].push(swapId);
        _byTaker[taker].push(swapId);

        emit OfferOpened(swapId, msg.sender, taker, tokenA, amountA, hashlock, deadline_);

        // Pull ERC20 from maker after state writes (CEI: state set, then external call).
        if (tokenA != address(0)) {
            _pull(tokenA, msg.sender, amountA);
        }
    }

    /// @notice Taker matches an open offer by locking tokenB.
    function openTaker(uint256 swapId, address tokenB, uint256 amountB) external payable {
        if (swapId >= swaps.length) revert InvalidSwap();
        Swap storage s = swaps[swapId];
        if (s.status != Status.Open) revert NotOpen();
        if (msg.sender != s.taker) revert NotTaker();
        if (block.timestamp >= s.deadline) revert DeadlinePassed();
        if (amountB == 0) revert ZeroValue();

        if (tokenB == address(0)) {
            if (msg.value != amountB) revert WrongValue();
        } else {
            if (msg.value != 0) revert WrongValue();
        }

        s.tokenB = tokenB;
        s.amountB = amountB;
        s.status = Status.Matched;

        emit OfferMatched(swapId, msg.sender, tokenB, amountB);

        if (tokenB != address(0)) {
            _pull(tokenB, msg.sender, amountB);
        }
    }

    /// @notice Reveal preimage and atomically pay tokenA→taker, tokenB→maker.
    /// @dev    Permissionless: anyone holding the preimage can settle. Either
    ///         party can therefore broadcast it once they have it. Fee is
    ///         skimmed from each leg and forwarded to treasury.
    function claim(uint256 swapId, bytes32 preimage) external {
        if (swapId >= swaps.length) revert InvalidSwap();
        Swap storage s = swaps[swapId];
        if (s.status != Status.Matched) revert NotMatched();
        if (keccak256(abi.encodePacked(preimage)) != s.hashlock) revert WrongPreimage();
        // Claim is allowed up to and including the deadline. After that, refund
        // is the only path so the parties get a clean exit window.
        if (block.timestamp > s.deadline) revert DeadlinePassed();

        uint256 amountA = s.amountA;
        uint256 amountB = s.amountB;
        address tokenA = s.tokenA;
        address tokenB = s.tokenB;
        address maker = s.maker;
        address taker = s.taker;

        uint16 feeBps = swapFeeBps;
        uint256 feeA = (amountA * feeBps) / BPS_DENOMINATOR;
        uint256 feeB = (amountB * feeBps) / BPS_DENOMINATOR;
        uint256 toTaker = amountA - feeA;
        uint256 toMaker = amountB - feeB;

        // Effects: zero out and mark claimed before any external transfers.
        s.amountA = 0;
        s.amountB = 0;
        s.status = Status.Claimed;

        emit Claimed(swapId, msg.sender, preimage, toTaker, toMaker, feeA, feeB);

        // Interactions: pay both legs + fees.
        _payOut(tokenA, taker, toTaker);
        _payOut(tokenB, maker, toMaker);
        if (feeA > 0) _payOut(tokenA, treasury, feeA);
        if (feeB > 0) _payOut(tokenB, treasury, feeB);
    }

    /// @notice Refund a participant's locked asset after the deadline.
    /// @dev    Each side refunds independently. If only the maker locked
    ///         (status still Open), only the maker can refund. Once both have
    ///         locked (Matched), each refunds their own side.
    function refund(uint256 swapId) external {
        if (swapId >= swaps.length) revert InvalidSwap();
        Swap storage s = swaps[swapId];
        if (block.timestamp <= s.deadline) revert DeadlineNotPassed();

        Status status = s.status;

        if (status == Status.Open) {
            // Only maker locked; only maker can refund.
            if (msg.sender != s.maker) revert NotParticipant();
            uint256 amount = s.amountA;
            address token = s.tokenA;
            s.amountA = 0;
            s.makerRefunded = true;
            s.status = Status.RefundedMaker;
            emit Refunded(swapId, msg.sender, amount, true);
            _payOut(token, msg.sender, amount);
            return;
        }

        if (status == Status.Matched || status == Status.RefundedMaker || status == Status.RefundedTaker) {
            bool isMaker = msg.sender == s.maker;
            bool isTaker = msg.sender == s.taker;
            if (!isMaker && !isTaker) revert NotParticipant();

            if (isMaker) {
                if (s.makerRefunded) revert AlreadyRefunded();
                uint256 amount = s.amountA;
                address token = s.tokenA;
                s.amountA = 0;
                s.makerRefunded = true;
                s.status = s.takerRefunded ? Status.RefundedBoth : Status.RefundedMaker;
                emit Refunded(swapId, msg.sender, amount, true);
                _payOut(token, msg.sender, amount);
            } else {
                if (s.takerRefunded) revert AlreadyRefunded();
                uint256 amount = s.amountB;
                address token = s.tokenB;
                s.amountB = 0;
                s.takerRefunded = true;
                s.status = s.makerRefunded ? Status.RefundedBoth : Status.RefundedTaker;
                emit Refunded(swapId, msg.sender, amount, false);
                _payOut(token, msg.sender, amount);
            }
            return;
        }

        revert NotMatched();
    }

    function setFees(uint16 newSwapFeeBps) external onlyTreasury {
        if (newSwapFeeBps > maxSwapFeeBps) revert FeeAboveCap();
        swapFeeBps = newSwapFeeBps;
        emit FeesUpdated(newSwapFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function totalSwaps() external view returns (uint256) {
        return swaps.length;
    }

    function swapsByMaker(address maker) external view returns (uint256[] memory) {
        return _byMaker[maker];
    }

    function swapsByTaker(address taker) external view returns (uint256[] memory) {
        return _byTaker[taker];
    }

    function getSwap(uint256 swapId) external view returns (Swap memory) {
        return swaps[swapId];
    }

    function _pull(address token, address from, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _payOut(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            (bool ok, bytes memory data) = token.call(
                abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
            );
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
    }
}
