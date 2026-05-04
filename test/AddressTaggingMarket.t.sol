// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AddressTaggingMarket} from "../src/AddressTaggingMarket.sol";

contract AddressTaggingMarketTest is Test {
    AddressTaggingMarket internal market;

    address internal constant TREASURY = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAFE);
    address internal subject = address(0x5EED);

    uint256 internal constant MIN_STAKE = 0.0001 ether;
    uint64 internal constant CHALLENGE_WINDOW = 7 days;
    uint16 internal constant ATTEST_FEE_BPS = 100; // 1%
    uint16 internal constant SLASH_TREASURY_BPS = 2000; // 20%
    uint16 internal constant MAX_FEE_BPS = 3000;

    function setUp() public {
        market = new AddressTaggingMarket(
            TREASURY,
            MIN_STAKE,
            CHALLENGE_WINDOW,
            ATTEST_FEE_BPS,
            SLASH_TREASURY_BPS,
            MAX_FEE_BPS
        );
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
    }

    // -------- attest --------

    function test_AttestStoresLabelAndStake() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "exchange:kraken");

        assertEq(id, 0);
        assertEq(market.totalAttestations(), 1);

        (
            address subj,
            address attester,
            address challenger,
            uint256 attestStake,
            uint256 counterStake,
            uint64 deadline,
            bool challenged,
            bool resolved,
            bool attesterWon,
            string memory label,
            string memory counterLabel
        ) = market.attestations(0);

        assertEq(subj, subject);
        assertEq(attester, alice);
        assertEq(challenger, address(0));
        assertEq(attestStake, 0.99 ether); // 1 ether minus 1% fee
        assertEq(counterStake, 0);
        assertEq(deadline, 0);
        assertFalse(challenged);
        assertFalse(resolved);
        assertFalse(attesterWon);
        assertEq(label, "exchange:kraken");
        assertEq(counterLabel, "");

        assertEq(TREASURY.balance, 0.01 ether);
    }

    function test_AttestRevertsBelowMinStake() public {
        // Send so little that post-fee is below min
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.StakeBelowMin.selector);
        market.attest{value: MIN_STAKE - 1}(subject, "lol");
    }

    function test_AttestRevertsZeroSubject() public {
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.ZeroAddress.selector);
        market.attest{value: 1 ether}(address(0), "x");
    }

    function test_AttestRevertsEmptyLabel() public {
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.LabelEmpty.selector);
        market.attest{value: 1 ether}(subject, "");
    }

    function test_AttestRevertsLabelTooLong() public {
        // 65 byte string
        string memory long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.LabelTooLong.selector);
        market.attest{value: 1 ether}(subject, long);
    }

    function test_AttestIndexesSubject() public {
        vm.prank(alice);
        market.attest{value: 1 ether}(subject, "label-a");
        vm.prank(bob);
        market.attest{value: 1 ether}(subject, "label-b");

        uint256[] memory ids = market.attestationsOf(subject);
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
    }

    // -------- challenge --------

    function test_ChallengeOpensWindow() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "exchange");
        // alice's stake = 0.99 ether; challenger needs >= 1.98 ether
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "scammer");

        (,, address challenger,, uint256 counterStake, uint64 deadline, bool challenged,,,, string memory counterLabel) = market.attestations(id);
        assertEq(challenger, bob);
        assertEq(counterStake, 2 ether);
        assertTrue(challenged);
        assertEq(counterLabel, "scammer");
        assertEq(deadline, block.timestamp + CHALLENGE_WINDOW);
    }

    function test_ChallengeRevertsBelowDouble() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        vm.expectRevert(AddressTaggingMarket.StakeBelowDouble.selector);
        market.challenge{value: 1 ether}(id, "y"); // attest stake 0.99, need >= 1.98
    }

    function test_ChallengeRevertsAlreadyChallenged() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "y");
        vm.prank(carol);
        vm.expectRevert(AddressTaggingMarket.AlreadyChallenged.selector);
        market.challenge{value: 5 ether}(id, "z");
    }

    function test_ChallengeRevertsUnknownAttestation() public {
        vm.prank(bob);
        vm.expectRevert(AddressTaggingMarket.UnknownAttestation.selector);
        market.challenge{value: 1 ether}(999, "y");
    }

    // -------- support --------

    function test_SupportFromAttesterAddsToAttestSide() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "y");

        uint64 firstDeadline = uint64(block.timestamp + CHALLENGE_WINDOW);
        skip(1 days);

        vm.prank(alice);
        market.support{value: 1.5 ether}(id);

        (,,, uint256 attestStake,, uint64 deadline,,,,, ) = market.attestations(id);
        assertEq(attestStake, 0.99 ether + 1.5 ether);
        // Deadline extends from now (after skip), not from original
        assertEq(deadline, block.timestamp + CHALLENGE_WINDOW);
        assertGt(deadline, firstDeadline);
    }

    function test_SupportFromThirdPartyAddsToAttestSide() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "y");

        vm.prank(carol);
        market.support{value: 1 ether}(id);

        (,,, uint256 attestStake, uint256 counterStake,,,,,,) = market.attestations(id);
        assertEq(attestStake, 0.99 ether + 1 ether);
        assertEq(counterStake, 2 ether);
    }

    function test_SupportFromChallengerAddsToCounterSide() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "y");

        vm.prank(bob);
        market.support{value: 0.5 ether}(id);

        (,,, uint256 attestStake, uint256 counterStake,,,,,,) = market.attestations(id);
        assertEq(attestStake, 0.99 ether);
        assertEq(counterStake, 2.5 ether);
    }

    function test_SupportRevertsZeroValue() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.ZeroValue.selector);
        market.support{value: 0}(id);
    }

    function test_SupportUnchallengedJustAddsStake() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(carol);
        market.support{value: 0.5 ether}(id);

        (,,, uint256 attestStake,, uint64 deadline,,,,,) = market.attestations(id);
        assertEq(attestStake, 0.99 ether + 0.5 ether);
        assertEq(deadline, 0);
    }

    // -------- resolve --------

    function test_ResolveAttesterWins() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "good");
        // alice stake: 0.99
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "bad");
        // bob stake: 2.0
        vm.prank(alice);
        market.support{value: 2 ether}(id);
        // alice stake: 2.99 > bob 2.0 → alice wins

        skip(CHALLENGE_WINDOW + 1);

        uint256 treasuryBefore = TREASURY.balance;
        uint256 aliceBefore = alice.balance;

        market.resolve(id);

        uint256 expectedTreasuryCut = (2 ether * uint256(SLASH_TREASURY_BPS)) / 10_000; // 0.4 ether
        uint256 expectedAlicePayout = 2.99 ether + (2 ether - expectedTreasuryCut); // 4.59 ether

        assertEq(TREASURY.balance - treasuryBefore, expectedTreasuryCut);
        assertEq(alice.balance - aliceBefore, expectedAlicePayout);

        (,,,,,,, bool resolved, bool attesterWon,,) = market.attestations(id);
        assertTrue(resolved);
        assertTrue(attesterWon);
    }

    function test_ResolveChallengerWins() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "good");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "bad");
        // bob stake: 5.0 > alice 0.99 → bob wins

        skip(CHALLENGE_WINDOW + 1);

        uint256 treasuryBefore = TREASURY.balance;
        uint256 bobBefore = bob.balance;

        market.resolve(id);

        uint256 expectedTreasuryCut = (0.99 ether * uint256(SLASH_TREASURY_BPS)) / 10_000;
        uint256 expectedBobPayout = 5 ether + (0.99 ether - expectedTreasuryCut);

        assertEq(TREASURY.balance - treasuryBefore, expectedTreasuryCut);
        assertEq(bob.balance - bobBefore, expectedBobPayout);

        (,,,,,,, bool resolved, bool attesterWon,,) = market.attestations(id);
        assertTrue(resolved);
        assertFalse(attesterWon);
    }

    function test_ResolveTiedStakeAttesterWins() public {
        // alice attests → 0.99 stake
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "good");
        // bob challenges with 1.98 → exactly 2x minimum
        vm.prank(bob);
        market.challenge{value: 1.98 ether}(id, "bad");
        // alice supports with 0.99 to bring her side to 1.98 → tie
        vm.prank(alice);
        market.support{value: 0.99 ether}(id);

        (,,, uint256 attestStake, uint256 counterStake,,,,,,) = market.attestations(id);
        assertEq(attestStake, counterStake);

        skip(CHALLENGE_WINDOW + 1);

        uint256 aliceBefore = alice.balance;
        market.resolve(id);

        (,,,,,,, , bool attesterWon,,) = market.attestations(id);
        assertTrue(attesterWon, "attester should win ties");
        // alice gets her 1.98 + 80% of bob's 1.98
        uint256 treasuryCut = (1.98 ether * uint256(SLASH_TREASURY_BPS)) / 10_000;
        assertEq(alice.balance - aliceBefore, 1.98 ether + (1.98 ether - treasuryCut));
    }

    function test_ResolveRevertsBeforeWindow() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 2 ether}(id, "y");

        vm.expectRevert(AddressTaggingMarket.WindowOpen.selector);
        market.resolve(id);

        skip(CHALLENGE_WINDOW - 1);
        vm.expectRevert(AddressTaggingMarket.WindowOpen.selector);
        market.resolve(id);
    }

    function test_ResolveRevertsNotChallenged() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.expectRevert(AddressTaggingMarket.NotChallenged.selector);
        market.resolve(id);
    }

    function test_ResolveDoubleResolveProtected() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "y");
        skip(CHALLENGE_WINDOW + 1);

        market.resolve(id);
        vm.expectRevert(AddressTaggingMarket.AlreadyResolved.selector);
        market.resolve(id);
    }

    function test_ResolveAnyoneCanCall() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "y");
        skip(CHALLENGE_WINDOW + 1);

        // Carol (uninvolved) calls resolve
        vm.prank(carol);
        market.resolve(id);

        (,,,,,,, bool resolved,,,) = market.attestations(id);
        assertTrue(resolved);
    }

    // -------- post-resolve invariants --------

    function test_CannotChallengeResolved() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "y");
        skip(CHALLENGE_WINDOW + 1);
        market.resolve(id);

        vm.prank(carol);
        vm.expectRevert(AddressTaggingMarket.AlreadyResolved.selector);
        market.challenge{value: 5 ether}(id, "z");
    }

    function test_CannotSupportResolved() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "x");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "y");
        skip(CHALLENGE_WINDOW + 1);
        market.resolve(id);

        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.AlreadyResolved.selector);
        market.support{value: 1 ether}(id);
    }

    // -------- topLabel --------

    function test_TopLabelEmptyForUnknownSubject() public view {
        (string memory label, uint256 stake) = market.topLabel(address(0xdead));
        assertEq(label, "");
        assertEq(stake, 0);
    }

    function test_TopLabelPicksHighestStake() public {
        vm.prank(alice);
        market.attest{value: 1 ether}(subject, "label-a");
        vm.prank(bob);
        market.attest{value: 5 ether}(subject, "label-b");
        vm.prank(carol);
        market.attest{value: 0.5 ether}(subject, "label-c");

        (string memory label, uint256 stake) = market.topLabel(subject);
        assertEq(label, "label-b");
        assertEq(stake, 4.95 ether); // 5 ether minus 1% fee
    }

    function test_TopLabelDuringChallengeShowsLeader() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "good");
        // alice: 0.99
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "bad");
        // bob: 5.0 leads

        (string memory label, uint256 stake) = market.topLabel(subject);
        assertEq(label, "bad");
        assertEq(stake, 5 ether);
    }

    function test_TopLabelAfterResolveShowsWinner() public {
        vm.prank(alice);
        uint256 id = market.attest{value: 1 ether}(subject, "good");
        vm.prank(bob);
        market.challenge{value: 5 ether}(id, "bad");
        skip(CHALLENGE_WINDOW + 1);
        market.resolve(id);

        (string memory label, uint256 stake) = market.topLabel(subject);
        assertEq(label, "bad");
        // bob's 5 ether stake is preserved as the winning weight
        assertEq(stake, 5 ether);
    }

    // -------- pagination --------

    function test_AttestationsOfPaginated() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            market.attest{value: 1 ether}(subject, "x");
        }
        (uint256[] memory page, uint256 total) = market.attestationsOfPaginated(subject, 1, 2);
        assertEq(total, 5);
        assertEq(page.length, 2);
        assertEq(page[0], 1);
        assertEq(page[1], 2);
    }

    function test_AttestationsOfPaginatedClampsEnd() public {
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(alice);
            market.attest{value: 1 ether}(subject, "x");
        }
        (uint256[] memory page, uint256 total) = market.attestationsOfPaginated(subject, 1, 100);
        assertEq(total, 3);
        assertEq(page.length, 2);
    }

    function test_AttestationsOfPaginatedStartBeyondTotal() public {
        vm.prank(alice);
        market.attest{value: 1 ether}(subject, "x");
        (uint256[] memory page, uint256 total) = market.attestationsOfPaginated(subject, 5, 10);
        assertEq(total, 1);
        assertEq(page.length, 0);
    }

    // -------- treasury admin --------

    function test_SetFeesOnlyTreasury() public {
        vm.prank(alice);
        vm.expectRevert(AddressTaggingMarket.NotTreasury.selector);
        market.setFees(50, 1000);

        vm.prank(TREASURY);
        market.setFees(50, 1000);
        assertEq(market.attestFeeBps(), 50);
        assertEq(market.slashTreasuryShareBps(), 1000);
    }

    function test_SetFeesAboveCapReverts() public {
        vm.prank(TREASURY);
        vm.expectRevert(AddressTaggingMarket.FeeAboveCap.selector);
        market.setFees(MAX_FEE_BPS + 1, 100);
    }

    function test_SetTreasury() public {
        vm.prank(TREASURY);
        market.setTreasury(alice);
        assertEq(market.treasury(), alice);
    }

    function test_SetMinStake() public {
        vm.prank(TREASURY);
        market.setMinStake(1 ether);
        assertEq(market.minStakeWei(), 1 ether);

        vm.prank(TREASURY);
        vm.expectRevert(AddressTaggingMarket.ZeroValue.selector);
        market.setMinStake(0);
    }

    // -------- constructor guards --------

    function test_ConstructorRevertsZeroTreasury() public {
        vm.expectRevert(AddressTaggingMarket.ZeroAddress.selector);
        new AddressTaggingMarket(address(0), MIN_STAKE, CHALLENGE_WINDOW, ATTEST_FEE_BPS, SLASH_TREASURY_BPS, MAX_FEE_BPS);
    }

    function test_ConstructorRevertsZeroMinStake() public {
        vm.expectRevert(AddressTaggingMarket.ZeroValue.selector);
        new AddressTaggingMarket(TREASURY, 0, CHALLENGE_WINDOW, ATTEST_FEE_BPS, SLASH_TREASURY_BPS, MAX_FEE_BPS);
    }

    function test_ConstructorRevertsZeroWindow() public {
        vm.expectRevert(AddressTaggingMarket.ZeroValue.selector);
        new AddressTaggingMarket(TREASURY, MIN_STAKE, 0, ATTEST_FEE_BPS, SLASH_TREASURY_BPS, MAX_FEE_BPS);
    }

    function test_ConstructorRevertsCapTooHigh() public {
        vm.expectRevert(AddressTaggingMarket.FeeAboveCap.selector);
        new AddressTaggingMarket(TREASURY, MIN_STAKE, CHALLENGE_WINDOW, ATTEST_FEE_BPS, SLASH_TREASURY_BPS, 10_001);
    }

    function test_ConstructorRevertsInitialFeeAboveCap() public {
        vm.expectRevert(AddressTaggingMarket.FeeAboveCap.selector);
        new AddressTaggingMarket(TREASURY, MIN_STAKE, CHALLENGE_WINDOW, MAX_FEE_BPS + 1, SLASH_TREASURY_BPS, MAX_FEE_BPS);
    }

    // -------- fuzz --------

    function testFuzz_AttestStakeMath(uint256 sent) public {
        sent = bound(sent, MIN_STAKE * 200 / 100, 50 ether); // ensure post-fee >= min
        vm.prank(alice);
        uint256 id = market.attest{value: sent}(subject, "x");
        uint256 expectedFee = (sent * ATTEST_FEE_BPS) / 10_000;
        uint256 expectedStake = sent - expectedFee;
        (,,, uint256 attestStake,,,,,,, ) = market.attestations(id);
        assertEq(attestStake, expectedStake);
    }
}
