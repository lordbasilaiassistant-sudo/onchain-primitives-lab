// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IPriceOracle {
    function latestAnswer() external view returns (int256);
}

/// @title ConditionalTokenDrop
/// @notice Merkle airdrop unlocked by a programmable condition. Project deposits
///         ERC20 + a merkle root of (recipient, amount) leaves and chooses an
///         unlock trigger: block height, unix timestamp, oracle threshold, or
///         manual unlock by the registrant. Until the trigger fires, no claims.
/// @dev Setup fee is a flat ETH amount paid on registerDrop() and forwarded to
///      treasury immediately. Treasury can lower the fee but never above the
///      immutable cap set at deploy. CEI ordering throughout; no reentrancy on
///      claim because tokens go to msg.sender after state writes.
contract ConditionalTokenDrop {
    enum ConditionType { None, BlockHeight, Timestamp, OracleThreshold, Manual }

    struct Drop {
        address registrant;
        IERC20 token;
        bytes32 merkleRoot;
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 conditionValue;
        address oracle;
        ConditionType conditionType;
        bool manuallyUnlocked;
        bool cancelled;
    }

    Drop[] public drops;
    mapping(address => uint256[]) private _byRegistrant;
    mapping(uint256 => mapping(address => bool)) public claimedBy;

    address public treasury;
    uint256 public setupFeeWei;
    uint256 public immutable maxSetupFeeWei;

    event DropRegistered(
        uint256 indexed id,
        address indexed registrant,
        address indexed token,
        uint256 totalAmount,
        bytes32 merkleRoot,
        ConditionType conditionType,
        uint256 conditionValue,
        address oracle,
        uint256 fee
    );
    event Claimed(uint256 indexed id, address indexed recipient, uint256 amount);
    event ManuallyUnlocked(uint256 indexed id);
    event Cancelled(uint256 indexed id, uint256 refunded);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event SetupFeeUpdated(uint256 oldFee, uint256 newFee);

    error NotRegistrant();
    error NotTreasury();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroRoot();
    error InvalidCondition();
    error OracleRequired();
    error OracleForbidden();
    error InsufficientFee();
    error FeeAboveCap();
    error AlreadyCancelled();
    error AlreadyClaimed();
    error AlreadyUnlocked();
    error ClaimsExist();
    error NotUnlocked();
    error InvalidProof();
    error ExceedsTotal();
    error TokenTransferFailed();
    error EthTransferFailed();
    error RefundFailed();

    modifier onlyRegistrant(uint256 id) {
        if (drops[id].registrant != msg.sender) revert NotRegistrant();
        _;
    }

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury, uint256 _setupFeeWei, uint256 _maxSetupFeeWei) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_setupFeeWei > _maxSetupFeeWei) revert FeeAboveCap();
        treasury = _treasury;
        setupFeeWei = _setupFeeWei;
        maxSetupFeeWei = _maxSetupFeeWei;
    }

    function registerDrop(
        IERC20 token,
        uint256 totalAmount,
        bytes32 merkleRoot,
        uint8 conditionType,
        uint256 conditionValue,
        address oracleAddress
    ) external payable returns (uint256 id) {
        if (address(token) == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (merkleRoot == bytes32(0)) revert ZeroRoot();
        if (conditionType == 0 || conditionType > uint8(ConditionType.Manual)) revert InvalidCondition();

        ConditionType ct = ConditionType(conditionType);
        if (ct == ConditionType.OracleThreshold) {
            if (oracleAddress == address(0)) revert OracleRequired();
        } else {
            if (oracleAddress != address(0)) revert OracleForbidden();
        }

        uint256 fee = setupFeeWei;
        if (msg.value < fee) revert InsufficientFee();

        id = drops.length;
        drops.push(Drop({
            registrant: msg.sender,
            token: token,
            merkleRoot: merkleRoot,
            totalAmount: totalAmount,
            claimedAmount: 0,
            conditionValue: conditionValue,
            oracle: oracleAddress,
            conditionType: ct,
            manuallyUnlocked: false,
            cancelled: false
        }));
        _byRegistrant[msg.sender].push(id);

        emit DropRegistered(
            id,
            msg.sender,
            address(token),
            totalAmount,
            merkleRoot,
            ct,
            conditionValue,
            oracleAddress,
            fee
        );

        if (!token.transferFrom(msg.sender, address(this), totalAmount)) revert TokenTransferFailed();

        if (fee > 0) _sendEth(treasury, fee);
        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    function isUnlocked(uint256 id) public view returns (bool) {
        Drop storage d = drops[id];
        if (d.cancelled) return false;
        ConditionType ct = d.conditionType;
        if (ct == ConditionType.BlockHeight) {
            return block.number >= d.conditionValue;
        } else if (ct == ConditionType.Timestamp) {
            return block.timestamp >= d.conditionValue;
        } else if (ct == ConditionType.OracleThreshold) {
            int256 answer = IPriceOracle(d.oracle).latestAnswer();
            if (answer < 0) return false;
            return uint256(answer) >= d.conditionValue;
        } else if (ct == ConditionType.Manual) {
            return d.manuallyUnlocked;
        }
        return false;
    }

    function claim(uint256 id, uint256 amount, bytes32[] calldata proof) external {
        Drop storage d = drops[id];
        if (d.cancelled) revert AlreadyCancelled();
        if (!isUnlocked(id)) revert NotUnlocked();
        if (claimedBy[id][msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!_verify(proof, d.merkleRoot, leaf)) revert InvalidProof();

        uint256 newClaimed = d.claimedAmount + amount;
        if (newClaimed > d.totalAmount) revert ExceedsTotal();

        claimedBy[id][msg.sender] = true;
        d.claimedAmount = newClaimed;

        emit Claimed(id, msg.sender, amount);

        if (!d.token.transfer(msg.sender, amount)) revert TokenTransferFailed();
    }

    function unlockManually(uint256 id) external onlyRegistrant(id) {
        Drop storage d = drops[id];
        if (d.cancelled) revert AlreadyCancelled();
        if (d.conditionType != ConditionType.Manual) revert InvalidCondition();
        if (d.manuallyUnlocked) revert AlreadyUnlocked();
        d.manuallyUnlocked = true;
        emit ManuallyUnlocked(id);
    }

    function cancel(uint256 id) external onlyRegistrant(id) {
        Drop storage d = drops[id];
        if (d.cancelled) revert AlreadyCancelled();
        // Allowed if not yet unlocked OR no claims have happened.
        if (isUnlocked(id) && d.claimedAmount > 0) revert ClaimsExist();

        uint256 refund = d.totalAmount - d.claimedAmount;
        d.cancelled = true;

        emit Cancelled(id, refund);

        if (refund > 0) {
            if (!d.token.transfer(d.registrant, refund)) revert TokenTransferFailed();
        }
    }

    function setSetupFee(uint256 newFee) external onlyTreasury {
        if (newFee > maxSetupFeeWei) revert FeeAboveCap();
        uint256 old = setupFeeWei;
        setupFeeWei = newFee;
        emit SetupFeeUpdated(old, newFee);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function totalDrops() external view returns (uint256) {
        return drops.length;
    }

    function dropsByRegistrant(address registrant) external view returns (uint256[] memory) {
        return _byRegistrant[registrant];
    }

    function remainingAmount(uint256 id) external view returns (uint256) {
        Drop storage d = drops[id];
        if (d.cancelled) return 0;
        return d.totalAmount - d.claimedAmount;
    }

    function _verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i = 0; i < proof.length; ++i) {
            bytes32 p = proof[i];
            computed = computed < p
                ? keccak256(abi.encodePacked(computed, p))
                : keccak256(abi.encodePacked(p, computed));
        }
        return computed == root;
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
