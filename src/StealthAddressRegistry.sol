// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StealthAddressRegistry
/// @notice EIP-5564 / EIP-6538 stealth meta-address registry + announcer.
///         Receivers publish a stealth meta-address (compressed spending +
///         viewing pubkey blob). Senders compute a one-time stealth address
///         off-chain and call announce() so the receiver's scanner can find
///         the payment via indexed event logs.
/// @dev    All cryptography happens off-chain. The contract just stores keys
///         and emits scannable events. Treasury can lower fees but never
///         above the immutable hard caps set at deploy.
contract StealthAddressRegistry {
    address public treasury;
    uint256 public registerFeeWei;
    uint256 public announceFeeWei;

    uint256 public immutable maxRegisterFeeWei;
    uint256 public immutable maxAnnounceFeeWei;

    mapping(address registrant => mapping(uint256 schemeId => bytes metaAddress)) private _metaAddresses;

    uint256 public totalAnnouncements;

    event StealthMetaAddressSet(
        address indexed registrant,
        uint256 indexed schemeId,
        bytes stealthMetaAddress,
        uint256 fee
    );
    event Announcement(
        uint256 indexed schemeId,
        address indexed stealthAddress,
        address indexed caller,
        bytes32 ephemeralPubKey,
        bytes metadata,
        uint256 fee
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FeesUpdated(uint256 registerFeeWei, uint256 announceFeeWei);

    error NotTreasury();
    error ZeroAddress();
    error InsufficientFee();
    error FeeAboveCap();
    error InvalidSchemeId();
    error EmptyMetaAddress();
    error TransferFailed();

    modifier onlyTreasury() {
        if (msg.sender != treasury) revert NotTreasury();
        _;
    }

    constructor(
        address _treasury,
        uint256 _registerFeeWei,
        uint256 _maxRegisterFeeWei,
        uint256 _announceFeeWei,
        uint256 _maxAnnounceFeeWei
    ) {
        if (_treasury == address(0)) revert ZeroAddress();
        if (_registerFeeWei > _maxRegisterFeeWei) revert FeeAboveCap();
        if (_announceFeeWei > _maxAnnounceFeeWei) revert FeeAboveCap();

        treasury = _treasury;
        registerFeeWei = _registerFeeWei;
        announceFeeWei = _announceFeeWei;
        maxRegisterFeeWei = _maxRegisterFeeWei;
        maxAnnounceFeeWei = _maxAnnounceFeeWei;
    }

    /// @notice Publish your stealth meta-address for a given scheme.
    /// @dev    schemeId 1 = secp256k1 (EIP-5564 default). Overwrites any prior
    ///         entry for (msg.sender, schemeId). Excess ETH above the fee is
    ///         forwarded to the treasury (treated as a tip).
    /// @param  schemeId            Scheme identifier (1 = secp256k1).
    /// @param  stealthMetaAddress  Encoded spending + viewing pubkey blob.
    function registerKeys(uint256 schemeId, bytes calldata stealthMetaAddress) external payable {
        if (schemeId == 0) revert InvalidSchemeId();
        if (stealthMetaAddress.length == 0) revert EmptyMetaAddress();
        uint256 fee = registerFeeWei;
        if (msg.value < fee) revert InsufficientFee();

        _metaAddresses[msg.sender][schemeId] = stealthMetaAddress;

        emit StealthMetaAddressSet(msg.sender, schemeId, stealthMetaAddress, msg.value);

        if (msg.value > 0) _send(treasury, msg.value);
    }

    /// @notice Announce a stealth payment so the receiver's scanner can find it.
    /// @dev    The contract does not move the payment itself — the sender
    ///         transfers funds directly to `stealthAddress` in a separate tx
    ///         (or the same bundle off-chain). This call only emits the log
    ///         that the receiver scans.
    /// @param  schemeId         Scheme identifier (must match meta-address scheme).
    /// @param  stealthAddress   The one-time address derived for this payment.
    /// @param  ephemeralPubKey  Sender's ephemeral pubkey (compressed, 32 bytes).
    /// @param  metadata         View tag + optional payment hint blob.
    function announce(
        uint256 schemeId,
        address stealthAddress,
        bytes32 ephemeralPubKey,
        bytes calldata metadata
    ) external payable {
        if (schemeId == 0) revert InvalidSchemeId();
        if (stealthAddress == address(0)) revert ZeroAddress();
        uint256 fee = announceFeeWei;
        if (msg.value < fee) revert InsufficientFee();

        unchecked { ++totalAnnouncements; }

        emit Announcement(schemeId, stealthAddress, msg.sender, ephemeralPubKey, metadata, msg.value);

        if (msg.value > 0) _send(treasury, msg.value);
    }

    function setFees(uint256 newRegisterFeeWei, uint256 newAnnounceFeeWei) external onlyTreasury {
        if (newRegisterFeeWei > maxRegisterFeeWei) revert FeeAboveCap();
        if (newAnnounceFeeWei > maxAnnounceFeeWei) revert FeeAboveCap();
        registerFeeWei = newRegisterFeeWei;
        announceFeeWei = newAnnounceFeeWei;
        emit FeesUpdated(newRegisterFeeWei, newAnnounceFeeWei);
    }

    function setTreasury(address newTreasury) external onlyTreasury {
        if (newTreasury == address(0)) revert ZeroAddress();
        address old = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(old, newTreasury);
    }

    function stealthMetaAddressOf(address registrant, uint256 schemeId) external view returns (bytes memory) {
        return _metaAddresses[registrant][schemeId];
    }

    function hasMetaAddress(address registrant, uint256 schemeId) external view returns (bool) {
        return _metaAddresses[registrant][schemeId].length != 0;
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
