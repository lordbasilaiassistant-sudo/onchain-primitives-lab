// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TimeCapsule
/// @notice Store an opaque ciphertext blob on-chain that is "sealed" until an
///         unlock condition (timestamp or block height) is met. Once unlocked,
///         anyone can call reveal() to emit the blob through an event so wallets
///         and indexers can render it for the recipient.
/// @dev WARNING: On-chain storage is public. The blob bytes are readable by
///      anyone from day zero via storage slots / archive nodes / event traces of
///      the seal() tx. This contract enforces *event-based reveal*, not
///      *cryptographic secrecy*. Encryption is the user's responsibility:
///      encrypt to the recipient's pubkey or use threshold MPC off-chain
///      BEFORE calling seal(). The "sealed" / "unlocked" status is a UX
///      convention to coordinate when wallets should attempt decryption, not a
///      privacy guarantee.
contract TimeCapsule {
    enum UnlockMode { Time, Block }

    struct Capsule {
        address creator;
        address recipient; // address(0) = public reveal
        uint64 unlockAt;   // timestamp or block number depending on mode
        UnlockMode mode;
        bool revealed;
        bytes ciphertext;
    }

    Capsule[] private _capsules;
    mapping(address => uint256[]) private _byCreator;
    mapping(address => uint256[]) private _byRecipient;

    address public treasury;
    uint256 public feePerByteWei;
    uint256 public immutable maxFeePerByteWei;

    event Sealed(
        uint256 indexed capsuleId,
        address indexed creator,
        address indexed recipient,
        uint64 unlockAt,
        UnlockMode mode,
        uint256 size,
        uint256 fee
    );
    event Revealed(uint256 indexed capsuleId, address indexed revealer, address indexed recipient, bytes ciphertext);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeePerByteUpdated(uint256 oldFee, uint256 newFee);

    error NotTreasury();
    error ZeroAddress();
    error EmptyBlob();
    error UnlockInPast();
    error InvalidMode();
    error FeeAboveCap();
    error InsufficientFee();
    error AlreadyRevealed();
    error StillSealed();
    error UnknownCapsule();
    error TransferFailed();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(address _treasury, uint256 _feePerByteWei, uint256 _maxFeePerByteWei) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_feePerByteWei > _maxFeePerByteWei) revert FeeAboveCap();

        treasury = _treasury;
        feePerByteWei = _feePerByteWei;
        maxFeePerByteWei = _maxFeePerByteWei;
    }

    /// @notice Seal a ciphertext blob with an unlock condition.
    /// @param ciphertext Opaque bytes — encrypt off-chain BEFORE calling.
    /// @param unlockAt Unix timestamp (mode=Time) or block number (mode=Block) at which reveal becomes callable.
    /// @param recipient Address allowed to "claim" the reveal in UI; address(0) = public.
    /// @param mode 0 = Time, 1 = Block.
    /// @return capsuleId Index of the new capsule.
    function seal(
        bytes calldata ciphertext,
        uint64 unlockAt,
        address recipient,
        uint8 mode
    ) external payable returns (uint256 capsuleId) {
        if (ciphertext.length == 0) revert EmptyBlob();
        if (mode > uint8(UnlockMode.Block)) revert InvalidMode();

        UnlockMode m = UnlockMode(mode);
        if (m == UnlockMode.Time) {
            if (unlockAt <= block.timestamp) revert UnlockInPast();
        } else {
            if (unlockAt <= block.number) revert UnlockInPast();
        }

        uint256 fee = ciphertext.length * feePerByteWei;
        if (msg.value < fee) revert InsufficientFee();

        capsuleId = _capsules.length;
        _capsules.push(Capsule({
            creator: msg.sender,
            recipient: recipient,
            unlockAt: unlockAt,
            mode: m,
            revealed: false,
            ciphertext: ciphertext
        }));
        _byCreator[msg.sender].push(capsuleId);
        if (recipient != address(0)) _byRecipient[recipient].push(capsuleId);

        emit Sealed(capsuleId, msg.sender, recipient, unlockAt, m, ciphertext.length, fee);

        // Refund excess, then forward fee to treasury (CEI: state already written, event already emitted).
        uint256 refund = msg.value - fee;
        if (refund > 0) _send(msg.sender, refund);
        if (fee > 0) _send(treasury, fee);
    }

    /// @notice Reveal a capsule once its unlock condition is met. Anyone may call.
    /// @dev The ciphertext bytes were already publicly readable from storage and
    ///      from the seal() calldata; this just makes them easy to index.
    function reveal(uint256 capsuleId) external {
        if (capsuleId >= _capsules.length) revert UnknownCapsule();
        Capsule storage c = _capsules[capsuleId];
        if (c.revealed) revert AlreadyRevealed();
        if (!_isUnlocked(c)) revert StillSealed();

        c.revealed = true;

        emit Revealed(capsuleId, msg.sender, c.recipient, c.ciphertext);
    }

    function isUnlocked(uint256 capsuleId) external view returns (bool) {
        if (capsuleId >= _capsules.length) revert UnknownCapsule();
        return _isUnlocked(_capsules[capsuleId]);
    }

    function getCapsule(uint256 capsuleId)
        external
        view
        returns (
            address creator,
            address recipient,
            uint64 unlockAt,
            UnlockMode mode,
            bool revealed,
            uint256 size
        )
    {
        if (capsuleId >= _capsules.length) revert UnknownCapsule();
        Capsule storage c = _capsules[capsuleId];
        return (c.creator, c.recipient, c.unlockAt, c.mode, c.revealed, c.ciphertext.length);
    }

    /// @notice Returns the raw ciphertext. Note: this was always publicly readable
    ///         via storage slots; this getter just makes that explicit.
    function peekCiphertext(uint256 capsuleId) external view returns (bytes memory) {
        if (capsuleId >= _capsules.length) revert UnknownCapsule();
        return _capsules[capsuleId].ciphertext;
    }

    function totalCapsules() external view returns (uint256) {
        return _capsules.length;
    }

    function capsulesByCreator(address creator) external view returns (uint256[] memory) {
        return _byCreator[creator];
    }

    function capsulesByRecipient(address recipient) external view returns (uint256[] memory) {
        return _byRecipient[recipient];
    }

    function quoteFee(uint256 size) external view returns (uint256) {
        return size * feePerByteWei;
    }

    function setFeePerByte(uint256 newFeePerByteWei) external onlyTreasury {
        if (newFeePerByteWei > maxFeePerByteWei) revert FeeAboveCap();
        uint256 old = feePerByteWei;
        feePerByteWei = newFeePerByteWei;
        emit FeePerByteUpdated(old, newFeePerByteWei);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function _isUnlocked(Capsule storage c) private view returns (bool) {
        if (c.mode == UnlockMode.Time) {
            return block.timestamp >= uint256(c.unlockAt);
        }
        return block.number >= uint256(c.unlockAt);
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
