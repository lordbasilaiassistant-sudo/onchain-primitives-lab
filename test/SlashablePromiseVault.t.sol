// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SlashablePromiseVault} from "../src/SlashablePromiseVault.sol";

contract RejectETH {
    // No receive/fallback; rejects all incoming ETH.
}

contract SlashablePromiseVaultTest is Test {
    SlashablePromiseVault internal vault;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal user = makeAddr("user");
    address internal nemesis = makeAddr("nemesis");
    address internal referee = makeAddr("referee");
    address internal slasher = makeAddr("slasher");
    address internal stranger = makeAddr("stranger");

    uint16 internal constant SUCCESS_FEE_BPS = 100; // 1%
    uint16 internal constant SLASH_FEE_BPS = 200;   // 2%
    uint16 internal constant SLASH_BOUNTY_BPS = 50; // 0.5%
    uint16 internal constant MAX_FEE_BPS = 1000;    // 10%

    uint256 internal constant STAKE = 1 ether;

    event Registered(
        uint256 indexed id,
        address indexed user,
        address indexed nemesis,
        address referee,
        uint256 staked,
        uint64 deadline,
        SlashablePromiseVault.Mode mode
    );
    event Succeeded(uint256 indexed id, address indexed caller, uint256 returned, uint256 fee);
    event Slashed(uint256 indexed id, address indexed slasher, uint256 toNemesis, uint256 bounty, uint256 fee);

    function setUp() public {
        vault = new SlashablePromiseVault(
            TREASURY,
            SUCCESS_FEE_BPS,
            SLASH_FEE_BPS,
            SLASH_BOUNTY_BPS,
            MAX_FEE_BPS
        );
        vm.deal(user, 100 ether);
        vm.deal(referee, 1 ether);
        vm.deal(slasher, 1 ether);
        vm.deal(stranger, 1 ether);
    }

    // ───────────────────────── constructor ─────────────────────────

    function test_constructor_setsState() public view {
        assertEq(vault.treasury(), TREASURY);
        assertEq(vault.successFeeBps(), SUCCESS_FEE_BPS);
        assertEq(vault.slashFeeBps(), SLASH_FEE_BPS);
        assertEq(vault.slashBountyBps(), SLASH_BOUNTY_BPS);
        assertEq(vault.maxFeeBps(), MAX_FEE_BPS);
        assertEq(vault.totalPromises(), 0);
    }

    function test_constructor_revertsOnZeroTreasury() public {
        vm.expectRevert(SlashablePromiseVault.ZeroAddress.selector);
        new SlashablePromiseVault(address(0), 100, 200, 50, 1000);
    }

    function test_constructor_revertsOnMaxFeeAboveHalf() public {
        // BPS_DENOMINATOR / 2 = 5000; 5001 should revert.
        vm.expectRevert(SlashablePromiseVault.FeeAboveCap.selector);
        new SlashablePromiseVault(TREASURY, 100, 200, 50, 5001);
    }

    function test_constructor_revertsOnFeeAboveMax() public {
        vm.expectRevert(SlashablePromiseVault.FeeAboveCap.selector);
        new SlashablePromiseVault(TREASURY, 1001, 200, 50, 1000);

        vm.expectRevert(SlashablePromiseVault.FeeAboveCap.selector);
        new SlashablePromiseVault(TREASURY, 100, 1001, 50, 1000);

        vm.expectRevert(SlashablePromiseVault.FeeAboveCap.selector);
        new SlashablePromiseVault(TREASURY, 100, 200, 1001, 1000);
    }

    // ───────────────────────── register ─────────────────────────

    function test_register_selfAttestMode() public {
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.expectEmit(true, true, true, true);
        emit Registered(0, user, nemesis, address(0), STAKE, deadline, SlashablePromiseVault.Mode.SelfAttest);

        vm.prank(user);
        uint256 id = vault.register{value: STAKE}(nemesis, address(0), deadline);

        assertEq(id, 0);
        assertEq(vault.totalPromises(), 1);

        (
            address pUser,
            address pNemesis,
            address pReferee,
            uint256 amount,
            uint64 pDeadline,
            SlashablePromiseVault.Mode mode,
            SlashablePromiseVault.Status status
        ) = vault.promises(0);

        assertEq(pUser, user);
        assertEq(pNemesis, nemesis);
        assertEq(pReferee, address(0));
        assertEq(amount, STAKE);
        assertEq(pDeadline, deadline);
        assertEq(uint8(mode), uint8(SlashablePromiseVault.Mode.SelfAttest));
        assertEq(uint8(status), uint8(SlashablePromiseVault.Status.Active));

        assertEq(address(vault).balance, STAKE);
        assertEq(vault.promisesByUser(user).length, 1);
        assertEq(vault.promisesByNemesis(nemesis).length, 1);
        assertEq(vault.promisesByReferee(referee).length, 0);
    }

    function test_register_counterpartyMode() public {
        uint64 deadline = uint64(block.timestamp + 7 days);

        vm.prank(user);
        uint256 id = vault.register{value: STAKE}(nemesis, referee, deadline);

        (, , address pReferee, , , SlashablePromiseVault.Mode mode, ) = vault.promises(id);
        assertEq(pReferee, referee);
        assertEq(uint8(mode), uint8(SlashablePromiseVault.Mode.Counterparty));
        assertEq(vault.promisesByReferee(referee).length, 1);
    }

    function test_register_revertsOnZeroValue() public {
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.ZeroValue.selector);
        vault.register{value: 0}(nemesis, address(0), uint64(block.timestamp + 1 days));
    }

    function test_register_revertsOnZeroNemesis() public {
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.ZeroAddress.selector);
        vault.register{value: STAKE}(address(0), address(0), uint64(block.timestamp + 1 days));
    }

    function test_register_revertsWhenNemesisIsSelf() public {
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.InvalidNemesis.selector);
        vault.register{value: STAKE}(user, address(0), uint64(block.timestamp + 1 days));
    }

    function test_register_revertsWhenRefereeIsSelf() public {
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.InvalidReferee.selector);
        vault.register{value: STAKE}(nemesis, user, uint64(block.timestamp + 1 days));
    }

    function test_register_revertsWhenRefereeIsNemesis() public {
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.InvalidReferee.selector);
        vault.register{value: STAKE}(nemesis, nemesis, uint64(block.timestamp + 1 days));
    }

    function test_register_revertsOnPastDeadline() public {
        vm.warp(1000);
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.DeadlineInPast.selector);
        vault.register{value: STAKE}(nemesis, address(0), uint64(block.timestamp));
    }

    // ───────────────────────── succeed ─────────────────────────

    function test_succeed_returnsFundsMinusFee() public {
        uint256 id = _registerSelfAttest();

        uint256 fee = (STAKE * SUCCESS_FEE_BPS) / 10_000;
        uint256 expectedReturn = STAKE - fee;
        uint256 userBefore = user.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.expectEmit(true, true, false, true);
        emit Succeeded(id, user, expectedReturn, fee);

        vm.prank(user);
        vault.succeed(id);

        assertEq(user.balance - userBefore, expectedReturn);
        assertEq(TREASURY.balance - treasuryBefore, fee);

        (, , , uint256 amount, , , SlashablePromiseVault.Status status) = vault.promises(id);
        assertEq(amount, 0);
        assertEq(uint8(status), uint8(SlashablePromiseVault.Status.Succeeded));
        assertEq(address(vault).balance, 0);
    }

    function test_succeed_revertsForNonUser() public {
        uint256 id = _registerSelfAttest();
        vm.prank(stranger);
        vm.expectRevert(SlashablePromiseVault.NotUser.selector);
        vault.succeed(id);
    }

    function test_succeed_revertsInCounterpartyMode() public {
        uint256 id = _registerCounterparty();
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.WrongMode.selector);
        vault.succeed(id);
    }

    function test_succeed_revertsAfterDeadline() public {
        uint256 id = _registerSelfAttest();
        vm.warp(block.timestamp + 8 days);
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.DeadlinePassed.selector);
        vault.succeed(id);
    }

    function test_succeed_revertsIfAlreadyResolved() public {
        uint256 id = _registerSelfAttest();
        vm.prank(user);
        vault.succeed(id);
        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.AlreadyResolved.selector);
        vault.succeed(id);
    }

    // ───────────────────────── confirm ─────────────────────────

    function test_confirm_releasesFunds() public {
        uint256 id = _registerCounterparty();

        uint256 fee = (STAKE * SUCCESS_FEE_BPS) / 10_000;
        uint256 expectedReturn = STAKE - fee;
        uint256 userBefore = user.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.expectEmit(true, true, false, true);
        emit Succeeded(id, referee, expectedReturn, fee);

        vm.prank(referee);
        vault.confirm(id);

        assertEq(user.balance - userBefore, expectedReturn);
        assertEq(TREASURY.balance - treasuryBefore, fee);

        (, , , , , , SlashablePromiseVault.Status status) = vault.promises(id);
        assertEq(uint8(status), uint8(SlashablePromiseVault.Status.Succeeded));
    }

    function test_confirm_revertsForNonReferee() public {
        uint256 id = _registerCounterparty();
        vm.prank(stranger);
        vm.expectRevert(SlashablePromiseVault.NotReferee.selector);
        vault.confirm(id);

        vm.prank(user);
        vm.expectRevert(SlashablePromiseVault.NotReferee.selector);
        vault.confirm(id);
    }

    function test_confirm_revertsInSelfAttestMode() public {
        uint256 id = _registerSelfAttest();
        vm.prank(referee);
        vm.expectRevert(SlashablePromiseVault.WrongMode.selector);
        vault.confirm(id);
    }

    function test_confirm_revertsAfterDeadline() public {
        uint256 id = _registerCounterparty();
        vm.warp(block.timestamp + 8 days);
        vm.prank(referee);
        vm.expectRevert(SlashablePromiseVault.DeadlinePassed.selector);
        vault.confirm(id);
    }

    // ───────────────────────── slash ─────────────────────────

    function test_slash_payoutSplit() public {
        uint256 id = _registerSelfAttest();
        vm.warp(block.timestamp + 8 days);

        uint256 fee = (STAKE * SLASH_FEE_BPS) / 10_000;
        uint256 bounty = (STAKE * SLASH_BOUNTY_BPS) / 10_000;
        uint256 toNemesis = STAKE - fee - bounty;

        uint256 nemesisBefore = nemesis.balance;
        uint256 slasherBefore = slasher.balance;
        uint256 treasuryBefore = TREASURY.balance;

        vm.expectEmit(true, true, false, true);
        emit Slashed(id, slasher, toNemesis, bounty, fee);

        vm.prank(slasher);
        vault.slash(id);

        assertEq(nemesis.balance - nemesisBefore, toNemesis);
        assertEq(slasher.balance - slasherBefore, bounty);
        assertEq(TREASURY.balance - treasuryBefore, fee);

        (, , , uint256 amount, , , SlashablePromiseVault.Status status) = vault.promises(id);
        assertEq(amount, 0);
        assertEq(uint8(status), uint8(SlashablePromiseVault.Status.Slashed));
        assertEq(address(vault).balance, 0);
    }

    function test_slash_canBeCalledByAnyone() public {
        uint256 id = _registerSelfAttest();
        vm.warp(block.timestamp + 8 days);
        vm.prank(stranger);
        vault.slash(id);
        (, , , , , , SlashablePromiseVault.Status status) = vault.promises(id);
        assertEq(uint8(status), uint8(SlashablePromiseVault.Status.Slashed));
    }

    function test_slash_revertsBeforeDeadline() public {
        uint256 id = _registerSelfAttest();
        vm.prank(slasher);
        vm.expectRevert(SlashablePromiseVault.DeadlineNotReached.selector);
        vault.slash(id);
    }

    function test_slash_revertsAtExactDeadline() public {
        uint64 deadline = uint64(block.timestamp + 7 days);
        vm.prank(user);
        uint256 id = vault.register{value: STAKE}(nemesis, address(0), deadline);

        vm.warp(deadline);
        vm.prank(slasher);
        vm.expectRevert(SlashablePromiseVault.DeadlineNotReached.selector);
        vault.slash(id);
    }

    function test_slash_doubleSlashReverts() public {
        uint256 id = _registerSelfAttest();
        vm.warp(block.timestamp + 8 days);
        vm.prank(slasher);
        vault.slash(id);

        vm.prank(slasher);
        vm.expectRevert(SlashablePromiseVault.AlreadyResolved.selector);
        vault.slash(id);
    }

    function test_slash_revertsIfAlreadySucceeded() public {
        uint256 id = _registerSelfAttest();
        vm.prank(user);
        vault.succeed(id);
        vm.warp(block.timestamp + 8 days);
        vm.prank(slasher);
        vm.expectRevert(SlashablePromiseVault.AlreadyResolved.selector);
        vault.slash(id);
    }

    function test_slash_revertsWhenNemesisCannotReceive() public {
        RejectETH bad = new RejectETH();
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(user);
        uint256 id = vault.register{value: STAKE}(address(bad), address(0), deadline);

        vm.warp(deadline + 1);
        vm.prank(slasher);
        vm.expectRevert(SlashablePromiseVault.TransferFailed.selector);
        vault.slash(id);
    }

    // ───────────────────────── admin ─────────────────────────

    function test_setFees_onlyTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(SlashablePromiseVault.NotTreasury.selector);
        vault.setFees(50, 100, 25);

        vm.prank(TREASURY);
        vault.setFees(50, 100, 25);
        assertEq(vault.successFeeBps(), 50);
        assertEq(vault.slashFeeBps(), 100);
        assertEq(vault.slashBountyBps(), 25);
    }

    function test_setFees_revertsAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(SlashablePromiseVault.FeeAboveCap.selector);
        vault.setFees(MAX_FEE_BPS + 1, 100, 25);
    }

    function test_setTreasury_onlyTreasury() public {
        address newT = makeAddr("newT");
        vm.prank(stranger);
        vm.expectRevert(SlashablePromiseVault.NotTreasury.selector);
        vault.setTreasury(newT);

        vm.prank(TREASURY);
        vault.setTreasury(newT);
        assertEq(vault.treasury(), newT);
    }

    function test_setTreasury_revertsOnZero() public {
        vm.prank(TREASURY);
        vm.expectRevert(SlashablePromiseVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
    }

    // ───────────────────────── views ─────────────────────────

    function test_isActive_isExpired() public {
        uint256 id = _registerSelfAttest();
        assertTrue(vault.isActive(id));
        assertFalse(vault.isExpired(id));

        vm.warp(block.timestamp + 8 days);
        assertTrue(vault.isActive(id));
        assertTrue(vault.isExpired(id));

        vm.prank(slasher);
        vault.slash(id);
        assertFalse(vault.isActive(id));
        assertFalse(vault.isExpired(id));
    }

    function test_views_indexLookups() public {
        _registerSelfAttest();
        _registerCounterparty();
        assertEq(vault.promisesByUser(user).length, 2);
        assertEq(vault.promisesByNemesis(nemesis).length, 2);
        assertEq(vault.promisesByReferee(referee).length, 1);
    }

    // ───────────────────────── fuzz ─────────────────────────

    function testFuzz_slash_neverOverpays(uint96 stake, uint16 bountyBps) public {
        stake = uint96(bound(uint256(stake), 1 wei, 50 ether));
        bountyBps = uint16(bound(uint256(bountyBps), 0, MAX_FEE_BPS));

        vm.prank(TREASURY);
        vault.setFees(SUCCESS_FEE_BPS, SLASH_FEE_BPS, bountyBps);

        vm.deal(user, stake);
        uint64 deadline = uint64(block.timestamp + 1 days);
        vm.prank(user);
        uint256 id = vault.register{value: stake}(nemesis, address(0), deadline);

        vm.warp(deadline + 1);
        uint256 supplyBefore = nemesis.balance + slasher.balance + TREASURY.balance + address(vault).balance;
        vm.prank(slasher);
        vault.slash(id);
        uint256 supplyAfter = nemesis.balance + slasher.balance + TREASURY.balance + address(vault).balance;

        // Conservation: contract drained, nothing minted.
        assertEq(supplyAfter, supplyBefore);
        assertEq(address(vault).balance, 0);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _registerSelfAttest() internal returns (uint256 id) {
        vm.prank(user);
        id = vault.register{value: STAKE}(nemesis, address(0), uint64(block.timestamp + 7 days));
    }

    function _registerCounterparty() internal returns (uint256 id) {
        vm.prank(user);
        id = vault.register{value: STAKE}(nemesis, referee, uint64(block.timestamp + 7 days));
    }
}
