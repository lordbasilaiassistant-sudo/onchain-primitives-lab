// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title GroupBountyPool
/// @notice Multi-user dead-man pool. N participants jointly fund a pool with a
///         shared beneficiary. Each must ping within `pingInterval`. When K of N
///         participants have lapsed, anyone can trigger payout to the beneficiary
///         and earn a bounty.
/// @dev Cancellation requires unanimous on-chain vote from every participant.
///      Fees auto-route to treasury on register and trigger — no claim() needed.
///      Treasury can lower fees but never above the immutable hard caps.
contract GroupBountyPool {
    struct Pool {
        address beneficiary;
        uint128 amount;          // current ETH balance held for the pool (after fees)
        uint64 pingInterval;
        uint8 thresholdK;
        uint8 participantCount;  // n
        uint8 cancelVotes;       // count of distinct participants who voted to cancel
        bool claimed;            // true after trigger() or cancel() resolves the pool
    }

    Pool[] private _pools;

    // poolId => participant => index+1 in participants array (0 means not a participant)
    mapping(uint256 => mapping(address => uint256)) private _participantIndexPlusOne;
    // poolId => list of participants (ordered, indices stable for life of pool)
    mapping(uint256 => address[]) private _participants;
    // poolId => participant => last ping timestamp (0 until first ping; createPool seeds all to creation time)
    mapping(uint256 => mapping(address => uint64)) private _lastPing;
    // poolId => participant => contribution recorded at create time (informational/event use)
    mapping(uint256 => mapping(address => uint256)) private _contribution;
    // poolId => participant => has voted to cancel
    mapping(uint256 => mapping(address => bool)) private _cancelVote;

    // reverse indexes
    mapping(address => uint256[]) private _byParticipant;
    mapping(address => uint256[]) private _byBeneficiary;

    address public treasury;
    uint16 public registerFeeBps;
    uint16 public triggerBountyBps;
    uint16 public triggerFeeBps;

    uint16 public immutable maxFeeBps;

    uint16 public constant BPS_DENOMINATOR = 10_000;

    event PoolCreated(
        uint256 indexed poolId,
        address indexed creator,
        address indexed beneficiary,
        uint8 thresholdK,
        uint8 participantCount,
        uint64 pingInterval,
        uint256 locked,
        uint256 fee
    );
    event Pinged(uint256 indexed poolId, address indexed participant, uint64 timestamp);
    event CancelVoted(uint256 indexed poolId, address indexed participant, uint8 votes, uint8 needed);
    event Cancelled(uint256 indexed poolId, uint256 refunded);
    event Triggered(
        uint256 indexed poolId,
        address indexed triggerer,
        address indexed beneficiary,
        uint8 missedCount,
        uint256 bounty,
        uint256 treasuryFee,
        uint256 toBeneficiary
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 registerFeeBps, uint16 triggerBountyBps, uint16 triggerFeeBps);

    error ZeroAddress();
    error ZeroValue();
    error LengthMismatch();
    error EmptyPool();
    error TooManyParticipants();
    error DuplicateParticipant();
    error InvalidThreshold();
    error InvalidInterval();
    error ContributionMismatch();
    error NotParticipant();
    error AlreadyClaimed();
    error AlreadyVoted();
    error ThresholdNotMet();
    error UnanimityNotReached();
    error FeeAboveCap();
    error NotTreasury();
    error TransferFailed();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint16 _registerFeeBps,
        uint16 _triggerBountyBps,
        uint16 _triggerFeeBps,
        uint16 _maxFeeBps
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_maxFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_registerFeeBps > _maxFeeBps) revert FeeAboveCap();
        if (_triggerBountyBps > _maxFeeBps) revert FeeAboveCap();
        if (_triggerFeeBps > _maxFeeBps) revert FeeAboveCap();
        if (uint256(_triggerBountyBps) + uint256(_triggerFeeBps) > BPS_DENOMINATOR) revert FeeAboveCap();

        treasury = _treasury;
        registerFeeBps = _registerFeeBps;
        triggerBountyBps = _triggerBountyBps;
        triggerFeeBps = _triggerFeeBps;
        maxFeeBps = _maxFeeBps;
    }

    /// @notice Create a new pool. msg.value must equal sum(contributions).
    /// @dev Caller does NOT need to be one of the participants — but typically is.
    function createPool(
        address[] calldata participants,
        uint256[] calldata contributions,
        address beneficiary,
        uint64 pingInterval,
        uint8 thresholdK
    ) external payable returns (uint256 poolId) {
        uint256 n = participants.length;
        if (n == 0) revert EmptyPool();
        if (n > 255) revert TooManyParticipants();
        if (contributions.length != n) revert LengthMismatch();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (pingInterval == 0) revert InvalidInterval();
        if (thresholdK == 0 || thresholdK > n) revert InvalidThreshold();

        uint256 sumContrib;
        for (uint256 i = 0; i < n; i++) {
            sumContrib += contributions[i];
        }
        if (sumContrib != msg.value) revert ContributionMismatch();
        if (msg.value == 0) revert ZeroValue();

        uint256 fee = (msg.value * registerFeeBps) / BPS_DENOMINATOR;
        uint256 locked = msg.value - fee;

        poolId = _pools.length;
        _pools.push(Pool({
            beneficiary: beneficiary,
            amount: uint128(locked),
            pingInterval: pingInterval,
            thresholdK: thresholdK,
            participantCount: uint8(n),
            cancelVotes: 0,
            claimed: false
        }));

        uint64 ts = uint64(block.timestamp);
        for (uint256 i = 0; i < n; i++) {
            address p = participants[i];
            if (p == address(0)) revert ZeroAddress();
            if (_participantIndexPlusOne[poolId][p] != 0) revert DuplicateParticipant();
            _participantIndexPlusOne[poolId][p] = i + 1;
            _participants[poolId].push(p);
            _lastPing[poolId][p] = ts;
            _contribution[poolId][p] = contributions[i];
            _byParticipant[p].push(poolId);
        }
        _byBeneficiary[beneficiary].push(poolId);

        emit PoolCreated(poolId, msg.sender, beneficiary, thresholdK, uint8(n), pingInterval, locked, fee);

        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Refresh your alive timestamp on a pool you're a participant of.
    function ping(uint256 poolId) external {
        Pool storage p = _pools[poolId];
        if (p.claimed) revert AlreadyClaimed();
        if (_participantIndexPlusOne[poolId][msg.sender] == 0) revert NotParticipant();
        uint64 ts = uint64(block.timestamp);
        _lastPing[poolId][msg.sender] = ts;
        emit Pinged(poolId, msg.sender, ts);
    }

    /// @notice Cast or rescind nothing — a one-way unanimous-cancel vote.
    /// @dev When vote count == participantCount, anyone may call `cancel` to refund pro-rata.
    function cancelVote(uint256 poolId) external {
        Pool storage p = _pools[poolId];
        if (p.claimed) revert AlreadyClaimed();
        if (_participantIndexPlusOne[poolId][msg.sender] == 0) revert NotParticipant();
        if (_cancelVote[poolId][msg.sender]) revert AlreadyVoted();

        _cancelVote[poolId][msg.sender] = true;
        uint8 votes = p.cancelVotes + 1;
        p.cancelVotes = votes;

        emit CancelVoted(poolId, msg.sender, votes, p.participantCount);
    }

    /// @notice Refund the pool pro-rata once every participant has voted to cancel.
    /// @dev Pro-rata uses recorded contributions BEFORE the register fee was deducted.
    ///      Refunds are scaled by (locked / msg.value at create), so each participant's
    ///      effective haircut equals the register fee they bore.
    function cancel(uint256 poolId) external {
        Pool storage p = _pools[poolId];
        if (p.claimed) revert AlreadyClaimed();
        if (p.cancelVotes != p.participantCount) revert UnanimityNotReached();

        uint256 amount = p.amount;
        p.amount = 0;
        p.claimed = true;

        // sum of original contributions == amount + register fee originally taken.
        // Use stored contributions array as the weight basis.
        address[] storage parts = _participants[poolId];
        uint256 n = parts.length;
        uint256 totalContrib;
        for (uint256 i = 0; i < n; i++) {
            totalContrib += _contribution[poolId][parts[i]];
        }

        emit Cancelled(poolId, amount);

        if (amount == 0 || totalContrib == 0) return;

        uint256 distributed;
        for (uint256 i = 0; i < n; i++) {
            address pp = parts[i];
            uint256 share;
            if (i == n - 1) {
                share = amount - distributed; // remainder to the last participant — avoids dust loss
            } else {
                share = (amount * _contribution[poolId][pp]) / totalContrib;
                distributed += share;
            }
            if (share > 0) _send(pp, share);
        }
    }

    /// @notice Trigger payout when at least K participants are past their ping deadline.
    function trigger(uint256 poolId) external {
        Pool storage p = _pools[poolId];
        if (p.claimed) revert AlreadyClaimed();

        (bool ready, uint8 missed) = _canTrigger(poolId);
        if (!ready) revert ThresholdNotMet();

        uint256 amount = p.amount;
        uint256 bounty = (amount * triggerBountyBps) / BPS_DENOMINATOR;
        uint256 treasuryFee = (amount * triggerFeeBps) / BPS_DENOMINATOR;
        uint256 toBeneficiary = amount - bounty - treasuryFee;
        address beneficiary = p.beneficiary;

        p.amount = 0;
        p.claimed = true;

        emit Triggered(poolId, msg.sender, beneficiary, missed, bounty, treasuryFee, toBeneficiary);

        if (bounty > 0) _send(msg.sender, bounty);
        if (treasuryFee > 0) _send(treasury, treasuryFee);
        if (toBeneficiary > 0) _send(beneficiary, toBeneficiary);
    }

    /// @notice Treasury setters — bounded by immutable maxFeeBps.
    function setFees(uint16 newRegisterFeeBps, uint16 newTriggerBountyBps, uint16 newTriggerFeeBps) external onlyTreasury {
        if (newRegisterFeeBps > maxFeeBps) revert FeeAboveCap();
        if (newTriggerBountyBps > maxFeeBps) revert FeeAboveCap();
        if (newTriggerFeeBps > maxFeeBps) revert FeeAboveCap();
        if (uint256(newTriggerBountyBps) + uint256(newTriggerFeeBps) > BPS_DENOMINATOR) revert FeeAboveCap();
        registerFeeBps = newRegisterFeeBps;
        triggerBountyBps = newTriggerBountyBps;
        triggerFeeBps = newTriggerFeeBps;
        emit FeesUpdated(newRegisterFeeBps, newTriggerBountyBps, newTriggerFeeBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    // -------- views --------

    function canTrigger(uint256 poolId) external view returns (bool ready, uint8 missedCount) {
        Pool storage p = _pools[poolId];
        if (p.claimed) return (false, 0);
        return _canTrigger(poolId);
    }

    function _canTrigger(uint256 poolId) private view returns (bool ready, uint8 missedCount) {
        Pool storage p = _pools[poolId];
        address[] storage parts = _participants[poolId];
        uint256 n = parts.length;
        uint64 interval = p.pingInterval;
        uint256 nowTs = block.timestamp;
        uint8 missed;
        for (uint256 i = 0; i < n; i++) {
            uint256 lp = _lastPing[poolId][parts[i]];
            if (nowTs > lp + interval) {
                missed++;
                if (missed >= p.thresholdK) {
                    return (true, missed);
                }
            }
        }
        return (false, missed);
    }

    function getPool(uint256 poolId) external view returns (
        address beneficiary,
        uint128 amount,
        uint64 pingInterval,
        uint8 thresholdK,
        uint8 participantCount,
        uint8 cancelVotes,
        bool claimed
    ) {
        Pool storage p = _pools[poolId];
        return (p.beneficiary, p.amount, p.pingInterval, p.thresholdK, p.participantCount, p.cancelVotes, p.claimed);
    }

    function getParticipants(uint256 poolId) external view returns (address[] memory) {
        return _participants[poolId];
    }

    function isParticipant(uint256 poolId, address who) external view returns (bool) {
        return _participantIndexPlusOne[poolId][who] != 0;
    }

    function lastPing(uint256 poolId, address who) external view returns (uint64) {
        return _lastPing[poolId][who];
    }

    function contributionOf(uint256 poolId, address who) external view returns (uint256) {
        return _contribution[poolId][who];
    }

    function hasVotedCancel(uint256 poolId, address who) external view returns (bool) {
        return _cancelVote[poolId][who];
    }

    function deadlineOf(uint256 poolId, address who) external view returns (uint64) {
        return _lastPing[poolId][who] + _pools[poolId].pingInterval;
    }

    function totalPools() external view returns (uint256) {
        return _pools.length;
    }

    function poolsByParticipant(address who) external view returns (uint256[] memory) {
        return _byParticipant[who];
    }

    function poolsByBeneficiary(address who) external view returns (uint256[] memory) {
        return _byBeneficiary[who];
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
