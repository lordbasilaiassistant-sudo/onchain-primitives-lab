// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ConditionalTokenDrop, IERC20, IPriceOracle} from "../src/ConditionalTokenDrop.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MockOracle is IPriceOracle {
    int256 public answer;
    function set(int256 _a) external { answer = _a; }
    function latestAnswer() external view returns (int256) { return answer; }
}

contract ConditionalTokenDropTest is Test {
    ConditionalTokenDrop drop;
    MockERC20 token;
    MockOracle oracle;

    address treasury = address(0x7a3E312Ec6e20a9F62fE2405938EB9060312E334);
    address alice;
    uint256 aliceKey;
    address bob;
    uint256 bobKey;
    address registrant = address(0xBEEF);

    uint256 constant SETUP_FEE = 0.001 ether;
    uint256 constant MAX_FEE = 0.01 ether;

    uint256 aliceAmt = 100e18;
    uint256 bobAmt = 200e18;
    uint256 totalAmt = 300e18;

    bytes32 aliceLeaf;
    bytes32 bobLeaf;
    bytes32 root;

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");

        drop = new ConditionalTokenDrop(treasury, SETUP_FEE, MAX_FEE);
        token = new MockERC20();
        oracle = new MockOracle();

        token.mint(registrant, totalAmt * 10);

        aliceLeaf = keccak256(bytes.concat(keccak256(abi.encode(alice, aliceAmt))));
        bobLeaf = keccak256(bytes.concat(keccak256(abi.encode(bob, bobAmt))));
        // sorted-pair root
        root = aliceLeaf < bobLeaf
            ? keccak256(abi.encodePacked(aliceLeaf, bobLeaf))
            : keccak256(abi.encodePacked(bobLeaf, aliceLeaf));

        vm.deal(registrant, 10 ether);
    }

    function _proofForAlice() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = bobLeaf;
    }

    function _proofForBob() internal view returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = aliceLeaf;
    }

    function _registerTimestamp(uint256 unlockAt) internal returns (uint256 id) {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        id = drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 2, unlockAt, address(0));
        vm.stopPrank();
    }

    function _registerBlock(uint256 blk) internal returns (uint256 id) {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        id = drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 1, blk, address(0));
        vm.stopPrank();
    }

    function _registerOracle(uint256 threshold) internal returns (uint256 id) {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        id = drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 3, threshold, address(oracle));
        vm.stopPrank();
    }

    function _registerManual() internal returns (uint256 id) {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        id = drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 4, 0, address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ tests

    function test_constructorRejectsZeroTreasury() public {
        vm.expectRevert(ConditionalTokenDrop.ZeroAddress.selector);
        new ConditionalTokenDrop(address(0), 0, 0);
    }

    function test_constructorRejectsFeeAboveCap() public {
        vm.expectRevert(ConditionalTokenDrop.FeeAboveCap.selector);
        new ConditionalTokenDrop(treasury, 2 ether, 1 ether);
    }

    function test_registerTimestampDropAndFeeFlow() public {
        uint256 treasuryBefore = treasury.balance;
        uint256 id = _registerTimestamp(block.timestamp + 1 days);
        assertEq(id, 0);
        assertEq(token.balanceOf(address(drop)), totalAmt);
        assertEq(treasury.balance, treasuryBefore + SETUP_FEE);
        assertEq(drop.totalDrops(), 1);
        uint256[] memory ids = drop.dropsByRegistrant(registrant);
        assertEq(ids.length, 1);
        assertEq(ids[0], 0);
    }

    function test_registerRefundsExcessEth() public {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        uint256 balBefore = registrant.balance;
        drop.registerDrop{value: 1 ether}(IERC20(address(token)), totalAmt, root, 4, 0, address(0));
        vm.stopPrank();
        assertEq(registrant.balance, balBefore - SETUP_FEE);
    }

    function test_registerRevertsInsufficientFee() public {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        vm.expectRevert(ConditionalTokenDrop.InsufficientFee.selector);
        drop.registerDrop{value: 0}(IERC20(address(token)), totalAmt, root, 4, 0, address(0));
        vm.stopPrank();
    }

    function test_registerRejectsInvalidConditionType() public {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        vm.expectRevert(ConditionalTokenDrop.InvalidCondition.selector);
        drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 0, 0, address(0));
        vm.expectRevert(ConditionalTokenDrop.InvalidCondition.selector);
        drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 5, 0, address(0));
        vm.stopPrank();
    }

    function test_registerOracleNeedsAddress() public {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        vm.expectRevert(ConditionalTokenDrop.OracleRequired.selector);
        drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 3, 1, address(0));
        vm.stopPrank();
    }

    function test_registerNonOracleRejectsOracleAddress() public {
        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        vm.expectRevert(ConditionalTokenDrop.OracleForbidden.selector);
        drop.registerDrop{value: SETUP_FEE}(IERC20(address(token)), totalAmt, root, 2, block.timestamp + 1, address(oracle));
        vm.stopPrank();
    }

    function test_claimAfterTimestampUnlock() public {
        uint256 unlockAt = block.timestamp + 1 days;
        uint256 id = _registerTimestamp(unlockAt);

        vm.expectRevert(ConditionalTokenDrop.NotUnlocked.selector);
        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());

        vm.warp(unlockAt);
        assertTrue(drop.isUnlocked(id));

        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());
        assertEq(token.balanceOf(alice), aliceAmt);
        assertTrue(drop.claimedBy(id, alice));

        vm.prank(bob);
        drop.claim(id, bobAmt, _proofForBob());
        assertEq(token.balanceOf(bob), bobAmt);
        assertEq(drop.remainingAmount(id), 0);
    }

    function test_claimRevertsOnDoubleClaim() public {
        uint256 id = _registerTimestamp(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.AlreadyClaimed.selector);
        drop.claim(id, aliceAmt, _proofForAlice());
    }

    function test_claimRevertsOnInvalidProof() public {
        uint256 id = _registerTimestamp(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        bytes32[] memory bad = new bytes32[](1);
        bad[0] = bytes32(uint256(0xdead));
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.InvalidProof.selector);
        drop.claim(id, aliceAmt, bad);
    }

    function test_claimRevertsOnTamperedAmount() public {
        uint256 id = _registerTimestamp(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.InvalidProof.selector);
        drop.claim(id, aliceAmt + 1, _proofForAlice());
    }

    function test_blockHeightUnlock() public {
        uint256 target = block.number + 10;
        uint256 id = _registerBlock(target);
        assertFalse(drop.isUnlocked(id));
        vm.roll(target);
        assertTrue(drop.isUnlocked(id));
        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());
        assertEq(token.balanceOf(alice), aliceAmt);
    }

    function test_oracleUnlock() public {
        uint256 id = _registerOracle(2000e8);
        oracle.set(1500e8);
        assertFalse(drop.isUnlocked(id));
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.NotUnlocked.selector);
        drop.claim(id, aliceAmt, _proofForAlice());

        oracle.set(2500e8);
        assertTrue(drop.isUnlocked(id));
        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());
        assertEq(token.balanceOf(alice), aliceAmt);
    }

    function test_oracleNegativeAnswerStaysLocked() public {
        uint256 id = _registerOracle(0);
        oracle.set(-1);
        assertFalse(drop.isUnlocked(id));
    }

    function test_manualUnlockOnlyByRegistrant() public {
        uint256 id = _registerManual();
        assertFalse(drop.isUnlocked(id));

        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.NotRegistrant.selector);
        drop.unlockManually(id);

        vm.prank(registrant);
        drop.unlockManually(id);
        assertTrue(drop.isUnlocked(id));

        vm.prank(registrant);
        vm.expectRevert(ConditionalTokenDrop.AlreadyUnlocked.selector);
        drop.unlockManually(id);
    }

    function test_manualUnlockRejectedOnNonManualDrop() public {
        uint256 id = _registerTimestamp(block.timestamp + 1 days);
        vm.prank(registrant);
        vm.expectRevert(ConditionalTokenDrop.InvalidCondition.selector);
        drop.unlockManually(id);
    }

    function test_cancelBeforeUnlockRefundsRegistrant() public {
        uint256 id = _registerTimestamp(block.timestamp + 1 days);
        uint256 balBefore = token.balanceOf(registrant);
        vm.prank(registrant);
        drop.cancel(id);
        assertEq(token.balanceOf(registrant), balBefore + totalAmt);
        assertEq(drop.remainingAmount(id), 0);
    }

    function test_cancelAfterUnlockButNoClaimsAllowed() public {
        uint256 unlockAt = block.timestamp + 1;
        uint256 id = _registerTimestamp(unlockAt);
        vm.warp(unlockAt + 1);
        assertTrue(drop.isUnlocked(id));
        vm.prank(registrant);
        drop.cancel(id);
        assertEq(token.balanceOf(registrant), totalAmt * 10 - totalAmt + totalAmt);
    }

    function test_cancelAfterClaimReverts() public {
        uint256 id = _registerTimestamp(block.timestamp + 1);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        drop.claim(id, aliceAmt, _proofForAlice());
        vm.prank(registrant);
        vm.expectRevert(ConditionalTokenDrop.ClaimsExist.selector);
        drop.cancel(id);
    }

    function test_cancelOnlyByRegistrant() public {
        uint256 id = _registerTimestamp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.NotRegistrant.selector);
        drop.cancel(id);
    }

    function test_doubleCancelReverts() public {
        uint256 id = _registerTimestamp(block.timestamp + 1 days);
        vm.prank(registrant);
        drop.cancel(id);
        vm.prank(registrant);
        vm.expectRevert(ConditionalTokenDrop.AlreadyCancelled.selector);
        drop.cancel(id);
    }

    function test_claimAfterCancelReverts() public {
        uint256 id = _registerTimestamp(block.timestamp + 1);
        vm.prank(registrant);
        drop.cancel(id);
        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        vm.expectRevert(ConditionalTokenDrop.AlreadyCancelled.selector);
        drop.claim(id, aliceAmt, _proofForAlice());
    }

    function test_setSetupFeeOnlyByTreasuryAndCapped() public {
        vm.expectRevert(ConditionalTokenDrop.NotTreasury.selector);
        drop.setSetupFee(0);

        vm.prank(treasury);
        vm.expectRevert(ConditionalTokenDrop.FeeAboveCap.selector);
        drop.setSetupFee(MAX_FEE + 1);

        vm.prank(treasury);
        drop.setSetupFee(0);
        assertEq(drop.setupFeeWei(), 0);

        vm.startPrank(registrant);
        token.approve(address(drop), totalAmt);
        drop.registerDrop{value: 0}(IERC20(address(token)), totalAmt, root, 4, 0, address(0));
        vm.stopPrank();
    }

    function test_setTreasury() public {
        address newT = address(0xCAFE);
        vm.prank(treasury);
        drop.setTreasury(newT);
        assertEq(drop.treasury(), newT);

        vm.prank(treasury);
        vm.expectRevert(ConditionalTokenDrop.NotTreasury.selector);
        drop.setTreasury(address(0xDEAD));
    }
}
