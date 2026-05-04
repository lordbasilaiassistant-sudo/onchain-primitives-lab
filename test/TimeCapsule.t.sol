// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimeCapsule} from "../src/TimeCapsule.sol";

contract TimeCapsuleTest is Test {
    TimeCapsule capsule;

    address constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    uint256 constant FEE_PER_BYTE = 1_000_000_000_000; // 0.000001 ETH = 1e12 wei
    uint256 constant MAX_FEE_PER_BYTE = 1e15;          // hard cap = 1000x default

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address keeper = address(0xC0DE);

    bytes constant SAMPLE = hex"deadbeefcafebabef00dfeed1234567890abcdef";

    event Sealed(
        uint256 indexed capsuleId,
        address indexed creator,
        address indexed recipient,
        uint64 unlockAt,
        TimeCapsule.UnlockMode mode,
        uint256 size,
        uint256 fee
    );
    event Revealed(uint256 indexed capsuleId, address indexed revealer, address indexed recipient, bytes ciphertext);
    event FeePerByteUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    function setUp() public {
        capsule = new TimeCapsule(TREASURY, FEE_PER_BYTE, MAX_FEE_PER_BYTE);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(keeper, 1 ether);
    }

    // -------- constructor --------

    function test_Constructor_SetsState() public view {
        assertEq(capsule.treasury(), TREASURY);
        assertEq(capsule.feePerByteWei(), FEE_PER_BYTE);
        assertEq(capsule.maxFeePerByteWei(), MAX_FEE_PER_BYTE);
        assertEq(capsule.totalCapsules(), 0);
    }

    function test_Constructor_RevertOnZeroTreasury() public {
        vm.expectRevert(TimeCapsule.ZeroAddress.selector);
        new TimeCapsule(address(0), FEE_PER_BYTE, MAX_FEE_PER_BYTE);
    }

    function test_Constructor_RevertWhenFeeAboveCap() public {
        vm.expectRevert(TimeCapsule.FeeAboveCap.selector);
        new TimeCapsule(TREASURY, MAX_FEE_PER_BYTE + 1, MAX_FEE_PER_BYTE);
    }

    // -------- seal --------

    function test_Seal_TimeMode_RoutesFeeToTreasury() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        uint256 expectedFee = SAMPLE.length * FEE_PER_BYTE;
        uint256 treasuryBefore = TREASURY.balance;

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Sealed(0, alice, bob, unlockAt, TimeCapsule.UnlockMode.Time, SAMPLE.length, expectedFee);
        uint256 id = capsule.seal{value: expectedFee}(SAMPLE, unlockAt, bob, 0);

        assertEq(id, 0);
        assertEq(capsule.totalCapsules(), 1);
        assertEq(TREASURY.balance - treasuryBefore, expectedFee);

        (address creator, address recipient, uint64 ua, TimeCapsule.UnlockMode mode, bool revealed, uint256 size) =
            capsule.getCapsule(0);
        assertEq(creator, alice);
        assertEq(recipient, bob);
        assertEq(ua, unlockAt);
        assertEq(uint8(mode), uint8(TimeCapsule.UnlockMode.Time));
        assertFalse(revealed);
        assertEq(size, SAMPLE.length);

        uint256[] memory aliceCaps = capsule.capsulesByCreator(alice);
        uint256[] memory bobCaps = capsule.capsulesByRecipient(bob);
        assertEq(aliceCaps.length, 1);
        assertEq(bobCaps.length, 1);
        assertEq(aliceCaps[0], 0);
        assertEq(bobCaps[0], 0);
    }

    function test_Seal_BlockMode() public {
        uint64 unlockAt = uint64(block.number + 100);
        uint256 fee = SAMPLE.length * FEE_PER_BYTE;

        vm.prank(alice);
        uint256 id = capsule.seal{value: fee}(SAMPLE, unlockAt, address(0), 1);

        (, address recipient, uint64 ua, TimeCapsule.UnlockMode mode,,) = capsule.getCapsule(id);
        assertEq(recipient, address(0));
        assertEq(ua, unlockAt);
        assertEq(uint8(mode), uint8(TimeCapsule.UnlockMode.Block));

        // Public reveal: recipient is zero, so capsulesByRecipient(0) should NOT track it.
        assertEq(capsule.capsulesByRecipient(address(0)).length, 0);
    }

    function test_Seal_RefundsExcessValue() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        uint256 fee = SAMPLE.length * FEE_PER_BYTE;
        uint256 sent = fee + 0.5 ether;
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        capsule.seal{value: sent}(SAMPLE, unlockAt, bob, 0);

        assertEq(alice.balance, aliceBefore - fee);
    }

    function test_Seal_ZeroFeeAccepted_WhenFeeIsZero() public {
        // Drop fee to zero via treasury so seal becomes free.
        vm.prank(TREASURY);
        capsule.setFeePerByte(0);

        vm.prank(alice);
        uint256 id = capsule.seal{value: 0}(SAMPLE, uint64(block.timestamp + 1 days), bob, 0);
        assertEq(id, 0);
    }

    function test_Seal_RevertOnEmptyBlob() public {
        vm.prank(alice);
        vm.expectRevert(TimeCapsule.EmptyBlob.selector);
        capsule.seal{value: 0}("", uint64(block.timestamp + 1 days), bob, 0);
    }

    function test_Seal_RevertOnInvalidMode() public {
        vm.prank(alice);
        vm.expectRevert(TimeCapsule.InvalidMode.selector);
        capsule.seal{value: 0}(SAMPLE, uint64(block.timestamp + 1 days), bob, 2);
    }

    function test_Seal_RevertOnUnlockInPastTime() public {
        vm.warp(1_000_000);
        vm.prank(alice);
        vm.expectRevert(TimeCapsule.UnlockInPast.selector);
        capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, uint64(block.timestamp), bob, 0);
    }

    function test_Seal_RevertOnUnlockInPastBlock() public {
        vm.roll(100);
        vm.prank(alice);
        vm.expectRevert(TimeCapsule.UnlockInPast.selector);
        capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, uint64(block.number), bob, 1);
    }

    function test_Seal_RevertOnInsufficientFee() public {
        uint256 fee = SAMPLE.length * FEE_PER_BYTE;
        vm.prank(alice);
        vm.expectRevert(TimeCapsule.InsufficientFee.selector);
        capsule.seal{value: fee - 1}(SAMPLE, uint64(block.timestamp + 1 days), bob, 0);
    }

    // -------- isUnlocked --------

    function test_IsUnlocked_TimeMode() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 0);

        assertFalse(capsule.isUnlocked(id));
        vm.warp(unlockAt - 1);
        assertFalse(capsule.isUnlocked(id));
        vm.warp(unlockAt);
        assertTrue(capsule.isUnlocked(id));
        vm.warp(unlockAt + 1000);
        assertTrue(capsule.isUnlocked(id));
    }

    function test_IsUnlocked_BlockMode() public {
        uint64 unlockAt = uint64(block.number + 50);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 1);

        assertFalse(capsule.isUnlocked(id));
        vm.roll(unlockAt - 1);
        assertFalse(capsule.isUnlocked(id));
        vm.roll(unlockAt);
        assertTrue(capsule.isUnlocked(id));
    }

    function test_IsUnlocked_RevertOnUnknown() public {
        vm.expectRevert(TimeCapsule.UnknownCapsule.selector);
        capsule.isUnlocked(999);
    }

    // -------- reveal --------

    function test_Reveal_AnyoneCanRevealAfterUnlock() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 0);

        vm.warp(unlockAt);

        vm.expectEmit(true, true, true, true);
        emit Revealed(id, keeper, bob, SAMPLE);
        vm.prank(keeper);
        capsule.reveal(id);

        (,,,, bool revealed,) = capsule.getCapsule(id);
        assertTrue(revealed);
    }

    function test_Reveal_RevertWhenStillSealed() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 0);

        vm.expectRevert(TimeCapsule.StillSealed.selector);
        capsule.reveal(id);
    }

    function test_Reveal_RevertWhenAlreadyRevealed() public {
        uint64 unlockAt = uint64(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 0);

        vm.warp(unlockAt);
        capsule.reveal(id);

        vm.expectRevert(TimeCapsule.AlreadyRevealed.selector);
        capsule.reveal(id);
    }

    function test_Reveal_RevertOnUnknown() public {
        vm.expectRevert(TimeCapsule.UnknownCapsule.selector);
        capsule.reveal(42);
    }

    // -------- peek / honesty --------

    function test_PeekCiphertext_ReadableEvenWhileSealed() public {
        // This test exists to make the README's honesty point explicit:
        // the bytes are public from the moment seal() lands.
        uint64 unlockAt = uint64(block.timestamp + 365 days);
        vm.prank(alice);
        uint256 id = capsule.seal{value: SAMPLE.length * FEE_PER_BYTE}(SAMPLE, unlockAt, bob, 0);

        bytes memory peeked = capsule.peekCiphertext(id);
        assertEq(peeked, SAMPLE);
        assertFalse(capsule.isUnlocked(id));
    }

    // -------- treasury admin --------

    function test_SetFeePerByte_OnlyTreasury() public {
        vm.expectRevert(TimeCapsule.NotTreasury.selector);
        capsule.setFeePerByte(0);

        vm.prank(TREASURY);
        vm.expectEmit(false, false, false, true);
        emit FeePerByteUpdated(FEE_PER_BYTE, FEE_PER_BYTE / 2);
        capsule.setFeePerByte(FEE_PER_BYTE / 2);
        assertEq(capsule.feePerByteWei(), FEE_PER_BYTE / 2);
    }

    function test_SetFeePerByte_RevertAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(TimeCapsule.FeeAboveCap.selector);
        capsule.setFeePerByte(MAX_FEE_PER_BYTE + 1);
    }

    function test_SetTreasury_OnlyTreasury() public {
        vm.expectRevert(TimeCapsule.NotTreasury.selector);
        capsule.setTreasury(alice);

        vm.prank(TREASURY);
        vm.expectEmit(true, true, false, false);
        emit TreasuryUpdated(TREASURY, alice);
        capsule.setTreasury(alice);
        assertEq(capsule.treasury(), alice);
    }

    function test_SetTreasury_RevertOnZero() public {
        vm.prank(TREASURY);
        vm.expectRevert(TimeCapsule.ZeroAddress.selector);
        capsule.setTreasury(address(0));
    }

    // -------- views --------

    function test_QuoteFee() public view {
        assertEq(capsule.quoteFee(0), 0);
        assertEq(capsule.quoteFee(1), FEE_PER_BYTE);
        assertEq(capsule.quoteFee(1024), 1024 * FEE_PER_BYTE);
    }

    // -------- fuzz --------

    function testFuzz_Seal_RoundTrip(uint16 sizeRaw, uint32 secondsAhead) public {
        uint256 size = uint256(sizeRaw) % 4096 + 1; // 1..4096 bytes
        uint64 unlockAt = uint64(block.timestamp) + uint64(secondsAhead) + 1;

        bytes memory blob = new bytes(size);
        for (uint256 i = 0; i < size; i++) blob[i] = bytes1(uint8(i));

        uint256 fee = size * FEE_PER_BYTE;
        vm.deal(alice, fee + 1 ether);
        vm.prank(alice);
        uint256 id = capsule.seal{value: fee}(blob, unlockAt, bob, 0);

        assertFalse(capsule.isUnlocked(id));
        vm.warp(unlockAt);
        assertTrue(capsule.isUnlocked(id));

        vm.prank(keeper);
        capsule.reveal(id);
        (,,,, bool revealed,) = capsule.getCapsule(id);
        assertTrue(revealed);
    }
}
