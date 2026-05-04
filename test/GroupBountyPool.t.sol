// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/GroupBountyPool.sol";

contract GroupBountyPoolTest is Test {
    GroupBountyPool internal pool;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal constant BENEFICIARY = address(0xBEEF);
    address internal constant KEEPER = address(0xCA11);

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA201);
    address internal dave = address(0xDA1E);
    address internal eve = address(0xE5E);

    // 1% register, 0.5% bounty, 0.5% treasury, max 5%
    uint256 internal constant REG = 100;
    uint256 internal constant BOUNTY = 50;
    uint256 internal constant TFEE = 50;
    uint256 internal constant MAXFEE = 500;

    uint64 internal constant INTERVAL = 1 days;

    function setUp() public {
        pool = new GroupBountyPool(TREASURY, uint16(REG), uint16(BOUNTY), uint16(TFEE), uint16(MAXFEE));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(eve, 100 ether);
        vm.deal(KEEPER, 1 ether);
    }

    // ---------- helpers ----------

    function _three() internal view returns (address[] memory parts, uint256[] memory contribs) {
        parts = new address[](3);
        parts[0] = alice;
        parts[1] = bob;
        parts[2] = carol;
        contribs = new uint256[](3);
        contribs[0] = 1 ether;
        contribs[1] = 2 ether;
        contribs[2] = 3 ether;
    }

    function _five() internal view returns (address[] memory parts, uint256[] memory contribs) {
        parts = new address[](5);
        parts[0] = alice;
        parts[1] = bob;
        parts[2] = carol;
        parts[3] = dave;
        parts[4] = eve;
        contribs = new uint256[](5);
        contribs[0] = 1 ether;
        contribs[1] = 1 ether;
        contribs[2] = 1 ether;
        contribs[3] = 1 ether;
        contribs[4] = 1 ether;
    }

    // ---------- constructor / config ----------

    function test_Constructor_RejectsZeroTreasury() public {
        vm.expectRevert(GroupBountyPool.ZeroAddress.selector);
        new GroupBountyPool(address(0), uint16(REG), uint16(BOUNTY), uint16(TFEE), uint16(MAXFEE));
    }

    function test_Constructor_RejectsMaxFeeAboveHalf() public {
        vm.expectRevert(GroupBountyPool.FeeAboveCap.selector);
        new GroupBountyPool(TREASURY, 0, 0, 0, 5001);
    }

    function test_Constructor_RejectsRegisterAboveMax() public {
        vm.expectRevert(GroupBountyPool.FeeAboveCap.selector);
        new GroupBountyPool(TREASURY, uint16(MAXFEE + 1), uint16(BOUNTY), uint16(TFEE), uint16(MAXFEE));
    }

    function test_Constructor_RejectsBountyPlusFeeOverDenominator() public {
        // Push bounty+fee over 10_000 with a max that allows them individually.
        vm.expectRevert(GroupBountyPool.FeeAboveCap.selector);
        new GroupBountyPool(TREASURY, 0, 5000, 5001, 5001);
    }

    // ---------- createPool ----------

    function test_CreatePool_HappyPath_3Participants() public {
        (address[] memory parts, uint256[] memory c) = _three();
        uint256 sent = 6 ether;

        vm.prank(alice);
        uint256 id = pool.createPool{value: sent}(parts, c, BENEFICIARY, INTERVAL, 2);

        assertEq(id, 0);
        assertEq(pool.totalPools(), 1);
        (address ben, uint128 amt, uint64 ivl, uint8 k, uint8 n, uint8 votes, bool claimed) = pool.getPool(0);
        assertEq(ben, BENEFICIARY);
        assertEq(amt, sent - (sent * REG) / 10_000);
        assertEq(ivl, INTERVAL);
        assertEq(k, 2);
        assertEq(n, 3);
        assertEq(votes, 0);
        assertFalse(claimed);
        assertEq(TREASURY.balance, (sent * REG) / 10_000);
        assertTrue(pool.isParticipant(0, alice));
        assertTrue(pool.isParticipant(0, bob));
        assertTrue(pool.isParticipant(0, carol));
        assertFalse(pool.isParticipant(0, dave));
    }

    function test_CreatePool_SingleParticipant_DegenerateCase() public {
        address[] memory parts = new address[](1);
        parts[0] = alice;
        uint256[] memory c = new uint256[](1);
        c[0] = 5 ether;

        vm.prank(alice);
        uint256 id = pool.createPool{value: 5 ether}(parts, c, BENEFICIARY, INTERVAL, 1);
        assertEq(id, 0);
        (, uint128 amt,, uint8 k, uint8 n,,) = pool.getPool(0);
        assertEq(k, 1);
        assertEq(n, 1);
        assertEq(amt, 5 ether - (5 ether * REG) / 10_000);

        // Skip past deadline → trigger
        vm.warp(block.timestamp + INTERVAL + 1);
        (bool ready, uint8 missed) = pool.canTrigger(id);
        assertTrue(ready);
        assertEq(missed, 1);
    }

    function test_CreatePool_RevertsOnEmptyPool() public {
        address[] memory parts = new address[](0);
        uint256[] memory c = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.EmptyPool.selector);
        pool.createPool{value: 0}(parts, c, BENEFICIARY, INTERVAL, 1);
    }

    function test_CreatePool_RevertsOnLengthMismatch() public {
        address[] memory parts = new address[](2);
        parts[0] = alice;
        parts[1] = bob;
        uint256[] memory c = new uint256[](1);
        c[0] = 1 ether;
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.LengthMismatch.selector);
        pool.createPool{value: 1 ether}(parts, c, BENEFICIARY, INTERVAL, 1);
    }

    function test_CreatePool_RevertsOnKGreaterThanN() public {
        // k=5 with only n=3 participants → InvalidThreshold
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.InvalidThreshold.selector);
        pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 5);
    }

    function test_CreatePool_RevertsOnZeroThreshold() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.InvalidThreshold.selector);
        pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 0);
    }

    function test_CreatePool_RevertsOnDuplicateParticipant() public {
        address[] memory parts = new address[](3);
        parts[0] = alice;
        parts[1] = bob;
        parts[2] = alice; // duplicate
        uint256[] memory c = new uint256[](3);
        c[0] = 1 ether;
        c[1] = 1 ether;
        c[2] = 1 ether;
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.DuplicateParticipant.selector);
        pool.createPool{value: 3 ether}(parts, c, BENEFICIARY, INTERVAL, 2);
    }

    function test_CreatePool_RevertsOnContributionMismatch() public {
        (address[] memory parts, uint256[] memory c) = _three();
        // contribs sum to 6, send 5
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.ContributionMismatch.selector);
        pool.createPool{value: 5 ether}(parts, c, BENEFICIARY, INTERVAL, 2);
    }

    function test_CreatePool_RevertsOnZeroBeneficiary() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.ZeroAddress.selector);
        pool.createPool{value: 6 ether}(parts, c, address(0), INTERVAL, 2);
    }

    function test_CreatePool_RevertsOnZeroInterval() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.InvalidInterval.selector);
        pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, 0, 2);
    }

    function test_CreatePool_RevertsOnZeroAddressParticipant() public {
        address[] memory parts = new address[](2);
        parts[0] = alice;
        parts[1] = address(0);
        uint256[] memory c = new uint256[](2);
        c[0] = 1 ether;
        c[1] = 1 ether;
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.ZeroAddress.selector);
        pool.createPool{value: 2 ether}(parts, c, BENEFICIARY, INTERVAL, 1);
    }

    // ---------- ping / canTrigger ----------

    function test_Ping_RefreshesTimestamp() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.warp(block.timestamp + 12 hours);
        vm.prank(bob);
        pool.ping(id);
        assertEq(pool.lastPing(id, bob), uint64(block.timestamp));
    }

    function test_Ping_RevertsForNonParticipant() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);
        vm.prank(dave);
        vm.expectRevert(GroupBountyPool.NotParticipant.selector);
        pool.ping(id);
    }

    function test_CanTrigger_PartialPings_BelowThreshold() public {
        // 5 participants, k=3. Only 2 lapse (3 still pinging).
        (address[] memory parts, uint256[] memory c) = _five();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 5 ether}(parts, c, BENEFICIARY, INTERVAL, 3);

        // Move forward 2 days. Refresh carol/dave/eve.
        vm.warp(block.timestamp + 2 days);
        vm.prank(carol); pool.ping(id);
        vm.prank(dave); pool.ping(id);
        vm.prank(eve); pool.ping(id);

        // alice + bob lapsed (2 missed), threshold k=3 → not ready
        (bool ready, uint8 missed) = pool.canTrigger(id);
        assertFalse(ready);
        assertEq(missed, 2);
    }

    // ---------- trigger ----------

    function test_Trigger_K1_AnyMissedTriggers() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 1);

        // Bob and carol ping, alice lapses
        vm.warp(block.timestamp + INTERVAL / 2);
        vm.prank(bob); pool.ping(id);
        vm.prank(carol); pool.ping(id);

        vm.warp(block.timestamp + INTERVAL + 1);
        // bob/carol last pinged at +12h, deadline +12h+1d = +1.5d. Now +1.5d+1 → bob/carol also lapse (interval-only).
        // For k=1 only one needs to lapse — alice does first; result: ready true.
        (bool ready, uint8 missed) = pool.canTrigger(id);
        assertTrue(ready);
        assertGe(missed, 1);

        uint256 amt = uint128(_amountOf(id));
        uint256 expectedBounty = (amt * BOUNTY) / 10_000;
        uint256 expectedTfee = (amt * TFEE) / 10_000;
        uint256 expectedToBen = amt - expectedBounty - expectedTfee;

        uint256 keeperBefore = KEEPER.balance;
        uint256 treasuryBefore = TREASURY.balance;
        uint256 benBefore = BENEFICIARY.balance;

        vm.prank(KEEPER);
        pool.trigger(id);

        assertEq(KEEPER.balance - keeperBefore, expectedBounty);
        assertEq(TREASURY.balance - treasuryBefore, expectedTfee);
        assertEq(BENEFICIARY.balance - benBefore, expectedToBen);

        (,, , , , , bool claimed) = pool.getPool(id);
        assertTrue(claimed);
    }

    function test_Trigger_KEqualsN_AllMustLapse() public {
        // 3 participants, k=3
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 3);

        // Move just past deadline — all lapsed simultaneously
        vm.warp(block.timestamp + INTERVAL + 1);
        (bool ready, uint8 missed) = pool.canTrigger(id);
        assertTrue(ready);
        assertEq(missed, 3);

        vm.prank(KEEPER);
        pool.trigger(id);
        (,, , , , , bool claimed) = pool.getPool(id);
        assertTrue(claimed);
    }

    function test_Trigger_KEqualsN_FailsIfOneStillAlive() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 3);

        vm.warp(block.timestamp + INTERVAL + 1);
        // Alice pings now → her deadline is the future. Bob/carol still lapsed.
        vm.prank(alice); pool.ping(id);

        (bool ready, uint8 missed) = pool.canTrigger(id);
        assertFalse(ready);
        assertEq(missed, 2);

        vm.prank(KEEPER);
        vm.expectRevert(GroupBountyPool.ThresholdNotMet.selector);
        pool.trigger(id);
    }

    function test_Trigger_RevertsBeforeThresholdMet() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        // Still inside interval
        vm.warp(block.timestamp + INTERVAL / 2);
        vm.prank(KEEPER);
        vm.expectRevert(GroupBountyPool.ThresholdNotMet.selector);
        pool.trigger(id);
    }

    function test_Trigger_DoubleTriggerReverts() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(KEEPER);
        pool.trigger(id);

        vm.prank(KEEPER);
        vm.expectRevert(GroupBountyPool.AlreadyClaimed.selector);
        pool.trigger(id);
    }

    // ---------- cancel-vote ----------

    function test_CancelVote_RequiresUnanimity() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.prank(alice); pool.cancelVote(id);
        vm.prank(bob); pool.cancelVote(id);
        // carol has not voted
        vm.expectRevert(GroupBountyPool.UnanimityNotReached.selector);
        pool.cancel(id);

        vm.prank(carol); pool.cancelVote(id);

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        uint256 carolBefore = carol.balance;

        pool.cancel(id);

        // 1% register fee was taken → 5.94 ether refunded total, split 1:2:3
        uint256 amt = 6 ether - (6 ether * REG) / 10_000; // 5.94 ether
        uint256 aliceShare = (amt * 1 ether) / 6 ether;
        uint256 bobShare = (amt * 2 ether) / 6 ether;
        uint256 carolShare = amt - aliceShare - bobShare; // last gets remainder

        assertEq(alice.balance - aliceBefore, aliceShare);
        assertEq(bob.balance - bobBefore, bobShare);
        assertEq(carol.balance - carolBefore, carolShare);

        (,, , , , , bool claimed) = pool.getPool(id);
        assertTrue(claimed);
    }

    function test_CancelVote_DoubleVoteReverts() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.prank(alice); pool.cancelVote(id);
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.AlreadyVoted.selector);
        pool.cancelVote(id);
    }

    function test_CancelVote_NonParticipantReverts() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.prank(dave);
        vm.expectRevert(GroupBountyPool.NotParticipant.selector);
        pool.cancelVote(id);
    }

    function test_Cancel_AfterTriggerReverts() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        uint256 id = pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(KEEPER);
        pool.trigger(id);

        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.AlreadyClaimed.selector);
        pool.cancelVote(id);
    }

    // ---------- treasury / fee admin ----------

    function test_SetFees_OnlyTreasury() public {
        vm.prank(alice);
        vm.expectRevert(GroupBountyPool.NotTreasury.selector);
        pool.setFees(50, 50, 50);
    }

    function test_SetFees_RejectsAboveCap() public {
        vm.prank(TREASURY);
        vm.expectRevert(GroupBountyPool.FeeAboveCap.selector);
        pool.setFees(uint16(MAXFEE + 1), uint16(BOUNTY), uint16(TFEE));
    }

    function test_SetTreasury_Works() public {
        vm.prank(TREASURY);
        pool.setTreasury(address(0xCAFE));
        assertEq(pool.treasury(), address(0xCAFE));
    }

    // ---------- views ----------

    function test_PoolsByParticipantAndBeneficiary_Indexed() public {
        (address[] memory parts, uint256[] memory c) = _three();
        vm.prank(alice);
        pool.createPool{value: 6 ether}(parts, c, BENEFICIARY, INTERVAL, 2);

        uint256[] memory aliceList = pool.poolsByParticipant(alice);
        assertEq(aliceList.length, 1);
        assertEq(aliceList[0], 0);

        uint256[] memory benList = pool.poolsByBeneficiary(BENEFICIARY);
        assertEq(benList.length, 1);
        assertEq(benList[0], 0);
    }

    // helper to read amount via getPool
    function _amountOf(uint256 id) internal view returns (uint256) {
        (, uint128 amt, , , , , ) = pool.getPool(id);
        return uint256(amt);
    }
}
