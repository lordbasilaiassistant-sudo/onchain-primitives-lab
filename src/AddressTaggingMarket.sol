// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AddressTaggingMarket
/// @notice Stake-weighted on-chain address labels with slashing.
/// @dev Anyone can attest "address X has label Y" by staking ETH. Stake = confidence
///      weight. Anyone can challenge by staking 2x with a counter-label. After a
///      challenge window with no further support added, the higher-staked side wins.
///      Loser's stake is split: 80% to winner, 20% to treasury. Attester wins ties
///      (incumbent bias — prevents free-grief by matching exact stake).
///      Treasury can lower fees but never above the immutable hard caps set at deploy.
contract AddressTaggingMarket {
    struct Attestation {
        address subject;
        address attester;
        address challenger;
        uint256 attestStake;
        uint256 counterStake;
        uint64 challengeDeadline;
        bool challenged;
        bool resolved;
        bool attesterWon;
        string label;
        string counterLabel;
    }

    Attestation[] public attestations;
    mapping(address => uint256[]) private _bySubject;

    address public treasury;
    uint16 public attestFeeBps;
    uint16 public slashTreasuryShareBps;
    uint256 public minStakeWei;

    uint16 public immutable maxFeeBps;
    uint64 public immutable challengeWindow;

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_LABEL_BYTES = 64;

    event Attested(uint256 indexed id, address indexed subject, address indexed attester, string label, uint256 stake, uint256 fee);
    event Challenged(uint256 indexed id, address indexed challenger, string counterLabel, uint256 counterStake, uint64 deadline);
    event Supported(uint256 indexed id, address indexed supporter, bool challengeSide, uint256 added, uint64 newDeadline);
    event Resolved(uint256 indexed id, bool attesterWon, uint256 winnerPayout, uint256 treasuryCut);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint16 attestFeeBps, uint16 slashTreasuryShareBps);
    event MinStakeUpdated(uint256 newMinStakeWei);

    error NotTreasury();
    error ZeroAddress();
    error ZeroValue();
    error LabelEmpty();
    error LabelTooLong();
    error StakeBelowMin();
    error StakeBelowDouble();
    error AlreadyChallenged();
    error AlreadyResolved();
    error NotChallenged();
    error WindowOpen();
    error UnknownAttestation();
    error FeeAboveCap();
    error TransferFailed();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint256 _minStakeWei,
        uint64 _challengeWindow,
        uint16 _attestFeeBps,
        uint16 _slashTreasuryShareBps,
        uint16 _maxFeeBps
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_minStakeWei == 0) revert ZeroValue();
        if (_challengeWindow == 0) revert ZeroValue();
        if (_maxFeeBps > BPS_DENOMINATOR / 2) revert FeeAboveCap();
        if (_attestFeeBps > _maxFeeBps) revert FeeAboveCap();
        if (_slashTreasuryShareBps > _maxFeeBps) revert FeeAboveCap();

        treasury = _treasury;
        minStakeWei = _minStakeWei;
        challengeWindow = _challengeWindow;
        attestFeeBps = _attestFeeBps;
        slashTreasuryShareBps = _slashTreasuryShareBps;
        maxFeeBps = _maxFeeBps;
    }

    /// @notice Post a stake-backed label for an address.
    /// @param subject The address being labeled.
    /// @param label The label string (≤64 bytes, non-empty).
    /// @return id The new attestation id.
    function attest(address subject, string calldata label) external payable returns (uint256 id) {
        if (subject == address(0)) revert ZeroAddress();
        uint256 labelLen = bytes(label).length;
        if (labelLen == 0) revert LabelEmpty();
        if (labelLen > MAX_LABEL_BYTES) revert LabelTooLong();

        uint256 fee = (msg.value * attestFeeBps) / BPS_DENOMINATOR;
        uint256 stake = msg.value - fee;
        if (stake < minStakeWei) revert StakeBelowMin();

        id = attestations.length;
        attestations.push();
        Attestation storage a = attestations[id];
        a.subject = subject;
        a.attester = msg.sender;
        a.attestStake = stake;
        a.label = label;

        _bySubject[subject].push(id);

        emit Attested(id, subject, msg.sender, label, stake, fee);

        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Challenge an existing attestation with a counter-label. Must stake
    ///         at least 2x the current attest stake (post-fee).
    /// @param attestationId The attestation to challenge.
    /// @param counterLabel The competing label.
    function challenge(uint256 attestationId, string calldata counterLabel) external payable {
        if (attestationId >= attestations.length) revert UnknownAttestation();
        Attestation storage a = attestations[attestationId];
        if (a.resolved) revert AlreadyResolved();
        if (a.challenged) revert AlreadyChallenged();

        uint256 labelLen = bytes(counterLabel).length;
        if (labelLen == 0) revert LabelEmpty();
        if (labelLen > MAX_LABEL_BYTES) revert LabelTooLong();
        if (msg.value < 2 * a.attestStake) revert StakeBelowDouble();

        a.challenged = true;
        a.challenger = msg.sender;
        a.counterStake = msg.value;
        a.counterLabel = counterLabel;
        a.challengeDeadline = uint64(block.timestamp) + challengeWindow;

        emit Challenged(attestationId, msg.sender, counterLabel, msg.value, a.challengeDeadline);
    }

    /// @notice Add stake to an existing attestation. If caller is the challenger,
    ///         stake adds to the counter side; otherwise it backs the original label.
    ///         If the attestation is already challenged, supporting it extends the
    ///         challenge deadline by `challengeWindow` (so the other side can react).
    /// @param attestationId The attestation to support.
    function support(uint256 attestationId) external payable {
        if (attestationId >= attestations.length) revert UnknownAttestation();
        if (msg.value == 0) revert ZeroValue();
        Attestation storage a = attestations[attestationId];
        if (a.resolved) revert AlreadyResolved();

        bool challengeSide = a.challenged && msg.sender == a.challenger;
        if (challengeSide) {
            a.counterStake += msg.value;
        } else {
            a.attestStake += msg.value;
        }

        uint64 newDeadline = a.challengeDeadline;
        if (a.challenged) {
            newDeadline = uint64(block.timestamp) + challengeWindow;
            a.challengeDeadline = newDeadline;
        }

        emit Supported(attestationId, msg.sender, challengeSide, msg.value, newDeadline);
    }

    /// @notice Resolve a challenged attestation after the window closes. Winner
    ///         takes their stake back plus 80% of the loser's stake; 20% to treasury.
    ///         Ties resolve in favor of the attester (incumbent bias).
    /// @param attestationId The attestation to resolve.
    function resolve(uint256 attestationId) external {
        if (attestationId >= attestations.length) revert UnknownAttestation();
        Attestation storage a = attestations[attestationId];
        if (a.resolved) revert AlreadyResolved();
        if (!a.challenged) revert NotChallenged();
        if (block.timestamp < a.challengeDeadline) revert WindowOpen();

        bool attesterWon = a.attestStake >= a.counterStake;
        uint256 winnerStake = attesterWon ? a.attestStake : a.counterStake;
        uint256 loserStake = attesterWon ? a.counterStake : a.attestStake;
        address winner = attesterWon ? a.attester : a.challenger;

        uint256 treasuryCut = (loserStake * slashTreasuryShareBps) / BPS_DENOMINATOR;
        uint256 winnerPayout = winnerStake + (loserStake - treasuryCut);

        // Note: attestStake/counterStake are NOT zeroed. They remain as the
        // historical stake snapshot so topLabel() can weight resolved winners
        // by their true stake. Re-entry/double-pay is prevented by the `resolved`
        // flag check at the top of this function.
        a.resolved = true;
        a.attesterWon = attesterWon;

        emit Resolved(attestationId, attesterWon, winnerPayout, treasuryCut);

        if (treasuryCut > 0) _send(treasury, treasuryCut);
        if (winnerPayout > 0) _send(winner, winnerPayout);
    }

    /// @notice Treasury can lower fees but never above the immutable cap.
    function setFees(uint16 newAttestFeeBps, uint16 newSlashTreasuryShareBps) external onlyTreasury {
        if (newAttestFeeBps > maxFeeBps) revert FeeAboveCap();
        if (newSlashTreasuryShareBps > maxFeeBps) revert FeeAboveCap();
        attestFeeBps = newAttestFeeBps;
        slashTreasuryShareBps = newSlashTreasuryShareBps;
        emit FeesUpdated(newAttestFeeBps, newSlashTreasuryShareBps);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function setMinStake(uint256 newMinStakeWei) external onlyTreasury {
        if (newMinStakeWei == 0) revert ZeroValue();
        minStakeWei = newMinStakeWei;
        emit MinStakeUpdated(newMinStakeWei);
    }

    /// @notice Returns all attestation ids for a subject. Note: O(n) in subject's
    ///         attestation count — clients with very heavy subjects should query
    ///         attestations one-by-one via the public `attestations(id)` getter
    ///         and use indexed events to discover ids off-chain.
    function attestationsOf(address subject) external view returns (uint256[] memory) {
        return _bySubject[subject];
    }

    /// @notice Paginated subject-attestation query for hot subjects.
    function attestationsOfPaginated(address subject, uint256 start, uint256 count)
        external
        view
        returns (uint256[] memory page, uint256 total)
    {
        uint256[] storage all = _bySubject[subject];
        total = all.length;
        if (start >= total) return (new uint256[](0), total);
        uint256 end = start + count;
        if (end > total) end = total;
        page = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            page[i - start] = all[i];
        }
    }

    /// @notice Highest-confidence label currently associated with an address.
    ///         Considers: unchallenged attestations, ongoing challenges (the
    ///         currently-leading side), and resolved attestations (the winner).
    /// @return label The winning label string. Empty if no attestations.
    /// @return stake The stake backing that label.
    function topLabel(address subject) external view returns (string memory label, uint256 stake) {
        uint256[] storage ids = _bySubject[subject];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; i++) {
            Attestation storage a = attestations[ids[i]];
            (string storage candidateLabel, uint256 candidateStake) = _currentSide(a);
            if (candidateStake > stake) {
                stake = candidateStake;
                label = candidateLabel;
            }
        }
    }

    function totalAttestations() external view returns (uint256) {
        return attestations.length;
    }

    /// @dev Returns the (label, stake) pair currently representing the
    ///      attestation. For resolved attestations, returns the winning side.
    ///      For active or ongoing-challenged attestations, returns the side
    ///      with more stake (attester wins ties).
    function _currentSide(Attestation storage a)
        private
        view
        returns (string storage label, uint256 stake)
    {
        if (a.resolved) {
            return a.attesterWon ? (a.label, a.attestStake) : (a.counterLabel, a.counterStake);
        }
        if (!a.challenged) {
            return (a.label, a.attestStake);
        }
        return a.attestStake >= a.counterStake ? (a.label, a.attestStake) : (a.counterLabel, a.counterStake);
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
