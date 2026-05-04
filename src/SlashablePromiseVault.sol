// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SlashablePromiseVault
/// @notice StickK-on-chain commitment device. Stake ETH against a goal with a
///         deadline and a named "nemesis" — the address that receives the stake
///         if you fail. Two verification modes:
///           - Self-attest: caller calls succeed() before deadline.
///           - Counterparty: caller names a referee at register; referee calls
///             confirm() to release funds.
///         If the deadline passes with no resolution, anyone can call slash():
///         funds go to the nemesis (minus protocol fee + slasher bounty).
/// @dev    Fees auto-route to treasury on every fee-bearing tx — no claim()
///         needed. Treasury can lower fees but never above the immutable cap.
contract SlashablePromiseVault {
    enum Mode {
        SelfAttest,
        Counterparty
    }

    enum Status {
        Active,
        Succeeded,
        Slashed
    }

    struct Promise {
        address user;
        address nemesis;
        address referee;
        uint256 amount;
        uint64 deadline;
        Mode mode;
        Status status;
    }

    Promise[] public promises;
    mapping(address => uint256[]) private _byUser;
    mapping(address => uint256[]) private _byNemesis;
    mapping(address => uint256[]) private _byReferee;

    address public treasury;
    uint16 public successFeeBps;
    uint16 public slashFeeBps;
    uint16 public slashBountyBps;

    uint16 public immutable maxFeeBps;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event Registered(
        uint256 indexed id,
        address indexed user,
        address indexed nemesis,
        address referee,
        uint256 staked,
        uint64 deadline,
        Mode mode
    );
    event Succeeded(uint256 indexed id, address indexed caller, uint256 returned, uint256 fee);
    event Slashed(uint256 indexed id, address indexed slasher, uint256 toNemesis, uint256 bounty, uint256 fee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 successFeeBps, uint16 slashFeeBps, uint16 slashBountyBps);

    error NotUser();
    error NotReferee();
    error NotTreasury();
    error WrongMode();
    error AlreadyResolved();
    error DeadlinePassed();
    error DeadlineNotReached();
    error DeadlineInPast();
    error ZeroValue();
    error ZeroAddress();
    error InvalidNemesis();
    error InvalidReferee();
    error FeeAboveCap();
    error TransferFailed();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint16 _successFeeBps,
        uint16 _slashFeeBps,
        uint16 _slashBountyBps,
        uint16 _maxFeeBps
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_successFeeBps > _maxFeeBps) revert FeeAboveCap();
        if (_slashFeeBps > _maxFeeBps) revert FeeAboveCap();
        if (_slashBountyBps > _maxFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        successFeeBps = _successFeeBps;
        slashFeeBps = _slashFeeBps;
        slashBountyBps = _slashBountyBps;
        maxFeeBps = _maxFeeBps;
    }

    function register(address nemesis, address referee, uint64 deadline_)
        external
        payable
        returns (uint256 id)
    {
        if (msg.value == 0) revert ZeroValue();
        if (nemesis == address(0)) revert ZeroAddress();
        if (nemesis == msg.sender) revert InvalidNemesis();
        if (deadline_ <= block.timestamp) revert DeadlineInPast();

        Mode mode;
        if (referee == address(0)) {
            mode = Mode.SelfAttest;
        } else {
            if (referee == msg.sender || referee == nemesis) revert InvalidReferee();
            mode = Mode.Counterparty;
        }

        id = promises.length;
        promises.push(Promise({
            user: msg.sender,
            nemesis: nemesis,
            referee: referee,
            amount: msg.value,
            deadline: deadline_,
            mode: mode,
            status: Status.Active
        }));

        _byUser[msg.sender].push(id);
        _byNemesis[nemesis].push(id);
        if (mode == Mode.Counterparty) _byReferee[referee].push(id);

        emit Registered(id, msg.sender, nemesis, referee, msg.value, deadline_, mode);
    }

    /// @notice Self-attest path. Only the user can call, only in SelfAttest mode,
    ///         only before the deadline.
    function succeed(uint256 id) external {
        Promise storage p = promises[id];
        if (p.status != Status.Active) revert AlreadyResolved();
        if (p.mode != Mode.SelfAttest) revert WrongMode();
        if (msg.sender != p.user) revert NotUser();
        if (block.timestamp > p.deadline) revert DeadlinePassed();

        _resolveSuccess(id, p);
    }

    /// @notice Counterparty path. Only the named referee can call, only in
    ///         Counterparty mode, only before the deadline.
    function confirm(uint256 id) external {
        Promise storage p = promises[id];
        if (p.status != Status.Active) revert AlreadyResolved();
        if (p.mode != Mode.Counterparty) revert WrongMode();
        if (msg.sender != p.referee) revert NotReferee();
        if (block.timestamp > p.deadline) revert DeadlinePassed();

        _resolveSuccess(id, p);
    }

    /// @notice Anyone can slash after the deadline. Funds go to nemesis minus
    ///         protocol fee, with a small bounty paid to the slasher.
    function slash(uint256 id) external {
        Promise storage p = promises[id];
        if (p.status != Status.Active) revert AlreadyResolved();
        if (block.timestamp <= p.deadline) revert DeadlineNotReached();

        uint256 amount = p.amount;
        address nemesis = p.nemesis;

        uint256 fee = (amount * slashFeeBps) / BPS_DENOMINATOR;
        uint256 bounty = (amount * slashBountyBps) / BPS_DENOMINATOR;
        uint256 toNemesis = amount - fee - bounty;

        p.amount = 0;
        p.status = Status.Slashed;

        emit Slashed(id, msg.sender, toNemesis, bounty, fee);

        if (fee > 0) _send(treasury, fee);
        if (bounty > 0) _send(msg.sender, bounty);
        if (toNemesis > 0) _send(nemesis, toNemesis);
    }

    function _resolveSuccess(uint256 id, Promise storage p) private {
        uint256 amount = p.amount;
        address user = p.user;

        uint256 fee = (amount * successFeeBps) / BPS_DENOMINATOR;
        uint256 returned = amount - fee;

        p.amount = 0;
        p.status = Status.Succeeded;

        emit Succeeded(id, msg.sender, returned, fee);

        if (fee > 0) _send(treasury, fee);
        if (returned > 0) _send(user, returned);
    }

    function setFees(uint16 newSuccessFeeBps, uint16 newSlashFeeBps, uint16 newSlashBountyBps)
        external
        onlyTreasury
    {
        if (newSuccessFeeBps > maxFeeBps) revert FeeAboveCap();
        if (newSlashFeeBps > maxFeeBps) revert FeeAboveCap();
        if (newSlashBountyBps > maxFeeBps) revert FeeAboveCap();
        successFeeBps = newSuccessFeeBps;
        slashFeeBps = newSlashFeeBps;
        slashBountyBps = newSlashBountyBps;
        emit FeesUpdated(newSuccessFeeBps, newSlashFeeBps, newSlashBountyBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function isActive(uint256 id) external view returns (bool) {
        return promises[id].status == Status.Active;
    }

    function isExpired(uint256 id) external view returns (bool) {
        Promise storage p = promises[id];
        return p.status == Status.Active && block.timestamp > p.deadline;
    }

    function totalPromises() external view returns (uint256) {
        return promises.length;
    }

    function promisesByUser(address user) external view returns (uint256[] memory) {
        return _byUser[user];
    }

    function promisesByNemesis(address nemesis) external view returns (uint256[] memory) {
        return _byNemesis[nemesis];
    }

    function promisesByReferee(address referee) external view returns (uint256[] memory) {
        return _byReferee[referee];
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
