// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AtomicSwapHTLC} from "../src/AtomicSwapHTLC.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AtomicSwapHTLCTest is Test {
    AtomicSwapHTLC htlc;
    MockERC20 tokenA;
    MockERC20 tokenB;

    address treasury = address(0x7a3E312Ec6e20a9F62fE2405938EB9060312E334);
    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    address stranger = address(0xC0DE);

    bytes32 secret = keccak256("super-secret-preimage");
    bytes32 hashlock;

    uint256 constant FEE_BPS = 50;          // 0.5%
    uint16 constant MAX_FEE_BPS = 500;      // 5%

    function setUp() public {
        htlc = new AtomicSwapHTLC(treasury, uint16(FEE_BPS), MAX_FEE_BPS);
        tokenA = new MockERC20();
        tokenB = new MockERC20();
        hashlock = keccak256(abi.encodePacked(secret));

        vm.deal(maker, 1000 ether);
        vm.deal(taker, 1000 ether);
        vm.deal(stranger, 10 ether);

        tokenA.mint(maker, 1_000_000e18);
        tokenB.mint(taker, 1_000_000e18);
    }

    function _openEthForToken(uint256 amountA, uint256 amountB, uint64 deadline)
        internal
        returns (uint256 swapId)
    {
        vm.prank(maker);
        swapId = htlc.openMaker{value: amountA}(hashlock, taker, address(0), amountA, deadline);

        vm.startPrank(taker);
        tokenB.approve(address(htlc), amountB);
        htlc.openTaker(swapId, address(tokenB), amountB);
        vm.stopPrank();
    }

    function _openTokenForToken(uint256 amountA, uint256 amountB, uint64 deadline)
        internal
        returns (uint256 swapId)
    {
        vm.startPrank(maker);
        tokenA.approve(address(htlc), amountA);
        swapId = htlc.openMaker(hashlock, taker, address(tokenA), amountA, deadline);
        vm.stopPrank();

        vm.startPrank(taker);
        tokenB.approve(address(htlc), amountB);
        htlc.openTaker(swapId, address(tokenB), amountB);
        vm.stopPrank();
    }

    // ---------- constructor ----------

    function testConstructorRejectsZeroTreasury() public {
        vm.expectRevert(AtomicSwapHTLC.ZeroAddress.selector);
        new AtomicSwapHTLC(address(0), uint16(FEE_BPS), MAX_FEE_BPS);
    }

    function testConstructorRejectsFeeAboveCap() public {
        vm.expectRevert(AtomicSwapHTLC.FeeAboveCap.selector);
        new AtomicSwapHTLC(treasury, uint16(600), uint16(500));
    }

    function testConstructorRejectsCapAboveHalf() public {
        vm.expectRevert(AtomicSwapHTLC.FeeAboveCap.selector);
        new AtomicSwapHTLC(treasury, uint16(0), uint16(5001));
    }

    // ---------- openMaker ----------

    function testOpenMakerEthLocksValue() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);
        assertEq(id, 0);
        assertEq(address(htlc).balance, 1 ether);
    }

    function testOpenMakerErc20PullsTokens() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.startPrank(maker);
        tokenA.approve(address(htlc), 100e18);
        htlc.openMaker(hashlock, taker, address(tokenA), 100e18, dl);
        vm.stopPrank();
        assertEq(tokenA.balanceOf(address(htlc)), 100e18);
    }

    function testOpenMakerRejectsSelfSwap() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.SelfSwap.selector);
        htlc.openMaker{value: 1 ether}(hashlock, maker, address(0), 1 ether, dl);
    }

    function testOpenMakerEthRejectsValueMismatch() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.WrongValue.selector);
        htlc.openMaker{value: 0.5 ether}(hashlock, taker, address(0), 1 ether, dl);
    }

    function testOpenMakerErc20RejectsNonZeroValue() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.WrongValue.selector);
        htlc.openMaker{value: 1}(hashlock, taker, address(tokenA), 100e18, dl);
    }

    function testOpenMakerRejectsPastDeadline() public {
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.DeadlinePassed.selector);
        htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, uint64(block.timestamp));
    }

    function testOpenMakerRejectsZeroHashlock() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.InvalidSwap.selector);
        htlc.openMaker{value: 1 ether}(bytes32(0), taker, address(0), 1 ether, dl);
    }

    // ---------- openTaker ----------

    function testOpenTakerOnlyDesignatedTaker() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);

        vm.prank(stranger);
        vm.expectRevert(AtomicSwapHTLC.NotTaker.selector);
        htlc.openTaker{value: 1 ether}(id, address(0), 1 ether);
    }

    function testOpenTakerRejectsAfterDeadline() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);

        vm.warp(dl + 1);
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.DeadlinePassed.selector);
        htlc.openTaker{value: 1 ether}(id, address(0), 1 ether);
    }

    function testOpenTakerRejectsDoubleMatch() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.NotOpen.selector);
        htlc.openTaker(id, address(tokenB), 100e18);
    }

    // ---------- claim happy path ----------

    function testClaimEthForTokenPaysBothLegsAndFees() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(10 ether, 1000e18, dl);

        uint256 takerBalBefore = taker.balance;
        uint256 makerTokenBefore = tokenB.balanceOf(maker);
        uint256 treasuryEthBefore = treasury.balance;
        uint256 treasuryTokenBefore = tokenB.balanceOf(treasury);

        vm.prank(stranger); // permissionless settlement
        htlc.claim(id, secret);

        uint256 feeA = (10 ether * FEE_BPS) / 10_000;
        uint256 feeB = (1000e18 * FEE_BPS) / 10_000;

        assertEq(taker.balance - takerBalBefore, 10 ether - feeA, "taker eth payout");
        assertEq(tokenB.balanceOf(maker) - makerTokenBefore, 1000e18 - feeB, "maker token payout");
        assertEq(treasury.balance - treasuryEthBefore, feeA, "treasury eth fee");
        assertEq(tokenB.balanceOf(treasury) - treasuryTokenBefore, feeB, "treasury token fee");
        assertEq(address(htlc).balance, 0, "no eth dust");
        assertEq(tokenB.balanceOf(address(htlc)), 0, "no token dust");
    }

    function testClaimTokenForTokenPaysBothLegs() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openTokenForToken(500e18, 800e18, dl);

        uint256 takerABefore = tokenA.balanceOf(taker);
        uint256 makerBBefore = tokenB.balanceOf(maker);

        vm.prank(maker);
        htlc.claim(id, secret);

        uint256 feeA = (500e18 * FEE_BPS) / 10_000;
        uint256 feeB = (800e18 * FEE_BPS) / 10_000;
        assertEq(tokenA.balanceOf(taker) - takerABefore, 500e18 - feeA);
        assertEq(tokenB.balanceOf(maker) - makerBBefore, 800e18 - feeB);
        assertEq(tokenA.balanceOf(treasury), feeA);
        assertEq(tokenB.balanceOf(treasury), feeB);
    }

    function testClaimEmitsEventWithPreimage() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        uint256 feeA = (1 ether * FEE_BPS) / 10_000;
        uint256 feeB = (100e18 * FEE_BPS) / 10_000;

        vm.expectEmit(true, true, false, true);
        emit AtomicSwapHTLC.Claimed(id, taker, secret, 1 ether - feeA, 100e18 - feeB, feeA, feeB);
        vm.prank(taker);
        htlc.claim(id, secret);
    }

    // ---------- claim sad paths ----------

    function testClaimRejectsWrongPreimage() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.WrongPreimage.selector);
        htlc.claim(id, keccak256("wrong"));
    }

    function testClaimRejectsBeforeMatch() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);

        // Maker has locked but taker has not — atomicity property:
        // taker side is empty, no one can claim.
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.NotMatched.selector);
        htlc.claim(id, secret);
    }

    function testClaimRejectsDoubleClaim() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.prank(taker);
        htlc.claim(id, secret);

        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.NotMatched.selector);
        htlc.claim(id, secret);
    }

    function testClaimRejectsAfterDeadline() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.warp(dl + 1);
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.DeadlinePassed.selector);
        htlc.claim(id, secret);
    }

    function testClaimRejectsInvalidSwapId() public {
        vm.expectRevert(AtomicSwapHTLC.InvalidSwap.selector);
        htlc.claim(999, secret);
    }

    // ---------- refund ----------

    function testRefundBeforeDeadlineReverts() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.DeadlineNotPassed.selector);
        htlc.refund(id);
    }

    function testRefundOpenOfferOnlyMaker() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);

        vm.warp(dl + 1);
        // taker hasn't locked anything yet → cannot refund the maker's leg
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.NotParticipant.selector);
        htlc.refund(id);

        uint256 makerBefore = maker.balance;
        vm.prank(maker);
        htlc.refund(id);
        assertEq(maker.balance - makerBefore, 1 ether);
    }

    function testRefundMatchedBothSidesRecoverIndependently() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(2 ether, 200e18, dl);

        vm.warp(dl + 1);

        uint256 makerEthBefore = maker.balance;
        vm.prank(maker);
        htlc.refund(id);
        assertEq(maker.balance - makerEthBefore, 2 ether, "maker refunded ETH");

        uint256 takerTokenBefore = tokenB.balanceOf(taker);
        vm.prank(taker);
        htlc.refund(id);
        assertEq(tokenB.balanceOf(taker) - takerTokenBefore, 200e18, "taker refunded token");
    }

    function testRefundRejectsDoubleRefund() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);
        vm.warp(dl + 1);

        vm.prank(maker);
        htlc.refund(id);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.AlreadyRefunded.selector);
        htlc.refund(id);
    }

    function testRefundRejectsStranger() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);
        vm.warp(dl + 1);

        vm.prank(stranger);
        vm.expectRevert(AtomicSwapHTLC.NotParticipant.selector);
        htlc.refund(id);
    }

    function testRefundAfterClaimReverts() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        vm.prank(taker);
        htlc.claim(id, secret);

        vm.warp(dl + 1);
        vm.prank(maker);
        vm.expectRevert(AtomicSwapHTLC.NotMatched.selector);
        htlc.refund(id);
    }

    // ---------- atomicity guarantee ----------

    function testAtomicityTakerCannotStealMakerLeg() public {
        // Taker tries to claim before they reveal their own lock — impossible
        // because openTaker is the only way to reach Matched, and openTaker
        // requires taker to actually lock asset B.
        uint64 dl = uint64(block.timestamp + 1 hours);
        vm.prank(maker);
        uint256 id = htlc.openMaker{value: 1 ether}(hashlock, taker, address(0), 1 ether, dl);

        // Even if taker had the preimage somehow, claim is gated on Matched.
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.NotMatched.selector);
        htlc.claim(id, secret);

        // And openTaker won't succeed without value.
        vm.prank(taker);
        vm.expectRevert(AtomicSwapHTLC.WrongValue.selector);
        htlc.openTaker(id, address(0), 1 ether);
    }

    function testAtomicityClaimReleasesBothLegsInOneTx() public {
        // The whole point: a single claim() call makes BOTH legs flow.
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 100e18, dl);

        // Snapshot — neither leg paid yet.
        assertEq(address(htlc).balance, 1 ether);
        assertEq(tokenB.balanceOf(address(htlc)), 100e18);

        vm.prank(stranger);
        htlc.claim(id, secret);

        // After: both legs zeroed and routed.
        assertEq(address(htlc).balance, 0);
        assertEq(tokenB.balanceOf(address(htlc)), 0);
    }

    // ---------- treasury admin ----------

    function testSetFeesOnlyTreasury() public {
        vm.prank(stranger);
        vm.expectRevert(AtomicSwapHTLC.NotTreasury.selector);
        htlc.setFees(100);

        vm.prank(treasury);
        htlc.setFees(100);
        assertEq(htlc.swapFeeBps(), 100);
    }

    function testSetFeesRejectsAboveCap() public {
        vm.prank(treasury);
        vm.expectRevert(AtomicSwapHTLC.FeeAboveCap.selector);
        htlc.setFees(MAX_FEE_BPS + 1);
    }

    function testSetTreasury() public {
        address newT = address(0xDEAD);
        vm.prank(treasury);
        htlc.setTreasury(newT);
        assertEq(htlc.treasury(), newT);
    }

    // ---------- view helpers ----------

    function testIndexes() public {
        uint64 dl = uint64(block.timestamp + 1 hours);
        uint256 id = _openEthForToken(1 ether, 10e18, dl);
        uint256[] memory mIds = htlc.swapsByMaker(maker);
        uint256[] memory tIds = htlc.swapsByTaker(taker);
        assertEq(mIds.length, 1);
        assertEq(tIds.length, 1);
        assertEq(mIds[0], id);
        assertEq(tIds[0], id);
        assertEq(htlc.totalSwaps(), 1);
    }

    receive() external payable {}
}
