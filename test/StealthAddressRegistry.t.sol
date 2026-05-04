// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StealthAddressRegistry} from "../src/StealthAddressRegistry.sol";

contract StealthAddressRegistryTest is Test {
    StealthAddressRegistry internal reg;

    address internal treasury = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal stealth = address(0x57EA17);

    uint256 internal constant REG_FEE = 0.0001 ether;
    uint256 internal constant MAX_REG_FEE = 0.001 ether;
    uint256 internal constant ANN_FEE = 0.00001 ether;
    uint256 internal constant MAX_ANN_FEE = 0.0001 ether;

    bytes internal constant META = hex"02b8c1b3a3b1c1d1e1f10203040506070809101112131415161718192021222324";

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

    function setUp() public {
        reg = new StealthAddressRegistry(treasury, REG_FEE, MAX_REG_FEE, ANN_FEE, MAX_ANN_FEE);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ---------- constructor ----------

    function test_constructor_setsState() public view {
        assertEq(reg.treasury(), treasury);
        assertEq(reg.registerFeeWei(), REG_FEE);
        assertEq(reg.announceFeeWei(), ANN_FEE);
        assertEq(reg.maxRegisterFeeWei(), MAX_REG_FEE);
        assertEq(reg.maxAnnounceFeeWei(), MAX_ANN_FEE);
        assertEq(reg.totalAnnouncements(), 0);
    }

    function test_constructor_revertsZeroTreasury() public {
        vm.expectRevert(StealthAddressRegistry.ZeroAddress.selector);
        new StealthAddressRegistry(address(0), REG_FEE, MAX_REG_FEE, ANN_FEE, MAX_ANN_FEE);
    }

    function test_constructor_revertsRegisterFeeAboveCap() public {
        vm.expectRevert(StealthAddressRegistry.FeeAboveCap.selector);
        new StealthAddressRegistry(treasury, MAX_REG_FEE + 1, MAX_REG_FEE, ANN_FEE, MAX_ANN_FEE);
    }

    function test_constructor_revertsAnnounceFeeAboveCap() public {
        vm.expectRevert(StealthAddressRegistry.FeeAboveCap.selector);
        new StealthAddressRegistry(treasury, REG_FEE, MAX_REG_FEE, MAX_ANN_FEE + 1, MAX_ANN_FEE);
    }

    // ---------- registerKeys ----------

    function test_registerKeys_storesAndForwardsFee() public {
        uint256 treasuryBefore = treasury.balance;

        vm.expectEmit(true, true, false, true, address(reg));
        emit StealthMetaAddressSet(alice, 1, META, REG_FEE);

        vm.prank(alice);
        reg.registerKeys{value: REG_FEE}(1, META);

        assertEq(treasury.balance - treasuryBefore, REG_FEE);
        assertEq(reg.stealthMetaAddressOf(alice, 1), META);
        assertTrue(reg.hasMetaAddress(alice, 1));
        assertFalse(reg.hasMetaAddress(alice, 2));
        assertFalse(reg.hasMetaAddress(bob, 1));
    }

    function test_registerKeys_overwritesPrior() public {
        bytes memory metaB = hex"03aa";
        vm.startPrank(alice);
        reg.registerKeys{value: REG_FEE}(1, META);
        reg.registerKeys{value: REG_FEE}(1, metaB);
        vm.stopPrank();
        assertEq(reg.stealthMetaAddressOf(alice, 1), metaB);
    }

    function test_registerKeys_multipleSchemes() public {
        bytes memory metaScheme2 = hex"feedface";
        vm.startPrank(alice);
        reg.registerKeys{value: REG_FEE}(1, META);
        reg.registerKeys{value: REG_FEE}(2, metaScheme2);
        vm.stopPrank();
        assertEq(reg.stealthMetaAddressOf(alice, 1), META);
        assertEq(reg.stealthMetaAddressOf(alice, 2), metaScheme2);
    }

    function test_registerKeys_excessForwardedAsTip() public {
        uint256 tip = 0.5 ether;
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        reg.registerKeys{value: REG_FEE + tip}(1, META);
        assertEq(treasury.balance - treasuryBefore, REG_FEE + tip);
    }

    function test_registerKeys_revertsInsufficientFee() public {
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.InsufficientFee.selector);
        reg.registerKeys{value: REG_FEE - 1}(1, META);
    }

    function test_registerKeys_revertsZeroSchemeId() public {
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.InvalidSchemeId.selector);
        reg.registerKeys{value: REG_FEE}(0, META);
    }

    function test_registerKeys_revertsEmptyMeta() public {
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.EmptyMetaAddress.selector);
        reg.registerKeys{value: REG_FEE}(1, hex"");
    }

    function test_registerKeys_zeroFeeAfterTreasuryLowers() public {
        vm.prank(treasury);
        reg.setFees(0, 0);
        uint256 treasuryBefore = treasury.balance;
        vm.prank(alice);
        reg.registerKeys{value: 0}(1, META);
        assertEq(treasury.balance, treasuryBefore);
        assertEq(reg.stealthMetaAddressOf(alice, 1), META);
    }

    // ---------- announce ----------

    function test_announce_emitsAndForwardsFee() public {
        bytes32 ephem = bytes32(uint256(0xEFEFEF));
        bytes memory meta = hex"01"; // view tag = 0x01

        uint256 treasuryBefore = treasury.balance;

        vm.expectEmit(true, true, true, true, address(reg));
        emit Announcement(1, stealth, bob, ephem, meta, ANN_FEE);

        vm.prank(bob);
        reg.announce{value: ANN_FEE}(1, stealth, ephem, meta);

        assertEq(treasury.balance - treasuryBefore, ANN_FEE);
        assertEq(reg.totalAnnouncements(), 1);
    }

    function test_announce_incrementsCounter() public {
        bytes32 ephem = bytes32(uint256(1));
        vm.startPrank(bob);
        reg.announce{value: ANN_FEE}(1, stealth, ephem, hex"01");
        reg.announce{value: ANN_FEE}(1, stealth, ephem, hex"02");
        reg.announce{value: ANN_FEE}(1, stealth, ephem, hex"03");
        vm.stopPrank();
        assertEq(reg.totalAnnouncements(), 3);
    }

    function test_announce_revertsInsufficientFee() public {
        vm.prank(bob);
        vm.expectRevert(StealthAddressRegistry.InsufficientFee.selector);
        reg.announce{value: ANN_FEE - 1}(1, stealth, bytes32(0), hex"01");
    }

    function test_announce_revertsZeroSchemeId() public {
        vm.prank(bob);
        vm.expectRevert(StealthAddressRegistry.InvalidSchemeId.selector);
        reg.announce{value: ANN_FEE}(0, stealth, bytes32(0), hex"01");
    }

    function test_announce_revertsZeroStealthAddress() public {
        vm.prank(bob);
        vm.expectRevert(StealthAddressRegistry.ZeroAddress.selector);
        reg.announce{value: ANN_FEE}(1, address(0), bytes32(0), hex"01");
    }

    function test_announce_emptyMetadataAllowed() public {
        vm.prank(bob);
        reg.announce{value: ANN_FEE}(1, stealth, bytes32(0), hex"");
        assertEq(reg.totalAnnouncements(), 1);
    }

    // ---------- treasury admin ----------

    function test_setFees_loweringWorks() public {
        vm.expectEmit(false, false, false, true, address(reg));
        emit FeesUpdated(0, 0);
        vm.prank(treasury);
        reg.setFees(0, 0);
        assertEq(reg.registerFeeWei(), 0);
        assertEq(reg.announceFeeWei(), 0);
    }

    function test_setFees_canSetUpToCap() public {
        vm.prank(treasury);
        reg.setFees(MAX_REG_FEE, MAX_ANN_FEE);
        assertEq(reg.registerFeeWei(), MAX_REG_FEE);
        assertEq(reg.announceFeeWei(), MAX_ANN_FEE);
    }

    function test_setFees_revertsAboveRegisterCap() public {
        vm.prank(treasury);
        vm.expectRevert(StealthAddressRegistry.FeeAboveCap.selector);
        reg.setFees(MAX_REG_FEE + 1, ANN_FEE);
    }

    function test_setFees_revertsAboveAnnounceCap() public {
        vm.prank(treasury);
        vm.expectRevert(StealthAddressRegistry.FeeAboveCap.selector);
        reg.setFees(REG_FEE, MAX_ANN_FEE + 1);
    }

    function test_setFees_revertsNotTreasury() public {
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.NotTreasury.selector);
        reg.setFees(0, 0);
    }

    function test_setTreasury_works() public {
        address newT = address(0xCAFE);
        vm.expectEmit(true, true, false, false, address(reg));
        emit TreasuryUpdated(treasury, newT);
        vm.prank(treasury);
        reg.setTreasury(newT);
        assertEq(reg.treasury(), newT);
    }

    function test_setTreasury_revertsZero() public {
        vm.prank(treasury);
        vm.expectRevert(StealthAddressRegistry.ZeroAddress.selector);
        reg.setTreasury(address(0));
    }

    function test_setTreasury_revertsNotTreasury() public {
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.NotTreasury.selector);
        reg.setTreasury(address(0xCAFE));
    }

    // ---------- transfer-failure path ----------

    function test_registerKeys_revertsIfTreasuryRejects() public {
        RejectingTreasury bad = new RejectingTreasury();
        StealthAddressRegistry r = new StealthAddressRegistry(
            address(bad), REG_FEE, MAX_REG_FEE, ANN_FEE, MAX_ANN_FEE
        );
        vm.prank(alice);
        vm.expectRevert(StealthAddressRegistry.TransferFailed.selector);
        r.registerKeys{value: REG_FEE}(1, META);
    }

    // ---------- fuzz ----------

    function testFuzz_registerKeys_anyMeta(uint256 schemeId, bytes calldata blob) public {
        vm.assume(schemeId != 0);
        vm.assume(blob.length > 0 && blob.length <= 1024);
        vm.prank(alice);
        reg.registerKeys{value: REG_FEE}(schemeId, blob);
        assertEq(reg.stealthMetaAddressOf(alice, schemeId), blob);
    }

    function testFuzz_announce_anyEphemAndMetadata(
        address sa,
        bytes32 ephem,
        bytes calldata md
    ) public {
        vm.assume(sa != address(0));
        vm.assume(md.length <= 1024);
        vm.prank(bob);
        reg.announce{value: ANN_FEE}(1, sa, ephem, md);
        assertEq(reg.totalAnnouncements(), 1);
    }
}

contract RejectingTreasury {
    receive() external payable {
        revert("nope");
    }
}
