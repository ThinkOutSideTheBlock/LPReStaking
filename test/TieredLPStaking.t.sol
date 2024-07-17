// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TieredLPStaking.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockLP is ERC20 {
    constructor() ERC20("Mock LP", "MLP") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }
}

contract MockReward is ERC20 {
    constructor() ERC20("Mock Reward", "MRW") {
        _mint(msg.sender, 1000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract TieredLPStakingTest is Test {
    TieredLPStaking public staking;
    MockLP public lpToken;
    MockReward public rewardToken;
    address public owner;
    address public alice;
    address public bob;

    uint256 public constant INITIAL_BALANCE = 10000 * 1e18;
    uint256 public constant STAKING_AMOUNT = 1000 * 1e18;
    uint256 public constant REWARD_RATE = 10 * 1e18; // 10 tokens per second
    uint256 public constant INITIAL_REWARD_BALANCE = 1000000000 * 1e18; // Increase initial reward balance

    function setUp() public {
        owner = address(this);
        alice = address(0x1);
        bob = address(0x2);

        lpToken = new MockLP();
        rewardToken = new MockReward();
        staking = new TieredLPStaking(address(lpToken), address(rewardToken));

        // Set up tiers
        staking.addTier(30 days, 1e12); // 1x multiplier for 30 days
        staking.addTier(90 days, 2e12); // 2x multiplier for 90 days
        staking.addTier(180 days, 3e12); // 3x multiplier for 180 days

        // Set reward rate
        staking.setRewardRate(REWARD_RATE);

        // Set staking cap
        staking.setStakingCap(1000000 * 1e18);

        // Distribute LP tokens
        lpToken.transfer(alice, INITIAL_BALANCE);
        lpToken.transfer(bob, INITIAL_BALANCE);

        // Approve staking contract
        vm.prank(alice);
        lpToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        lpToken.approve(address(staking), type(uint256).max);

        // Mint additional reward tokens to this contract
        rewardToken.mint(address(this), INITIAL_REWARD_BALANCE);

        // Fund staking contract with reward tokens
        rewardToken.transfer(address(staking), INITIAL_REWARD_BALANCE);
    }

    function testStaking() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // Stake in the 30-day tier

        assertEq(lpToken.balanceOf(address(staking)), STAKING_AMOUNT);
        assertEq(staking.getTotalStakedAmount(alice), STAKING_AMOUNT);
    }

    function testMultipleStakes() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // 30-day tier

        vm.prank(bob);
        staking.stake(STAKING_AMOUNT * 2, 1); // 90-day tier

        assertEq(staking.getTotalStakedAmount(alice), STAKING_AMOUNT);
        assertEq(staking.getTotalStakedAmount(bob), STAKING_AMOUNT * 2);
    }

    function testUnstaking() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // 30-day tier

        vm.warp(block.timestamp + 31 days);

        uint256 balanceBefore = lpToken.balanceOf(alice);
        uint256 rewardBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.unstake(0);

        uint256 balanceAfter = lpToken.balanceOf(alice);
        uint256 rewardAfter = rewardToken.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, STAKING_AMOUNT);
        assertTrue(rewardAfter > rewardBefore);
    }

    function testEmergencyWithdraw() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 1); // 90-day tier

        vm.warp(block.timestamp + 30 days);

        uint256 balanceBefore = lpToken.balanceOf(alice);

        vm.prank(alice);
        staking.emergencyWithdraw(0);

        uint256 balanceAfter = lpToken.balanceOf(alice);
        uint256 expectedReturn = (STAKING_AMOUNT * 90) / 100; // 10% penalty

        assertEq(balanceAfter - balanceBefore, expectedReturn);
    }

    function testClaimRewards() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // 30-day tier

        uint256 startTime = block.timestamp;
        vm.warp(block.timestamp + 15 days);

        uint256 rewardBefore = rewardToken.balanceOf(alice);

        vm.prank(alice);
        staking.claimRewards();

        uint256 rewardAfter = rewardToken.balanceOf(alice);
        uint256 actualReward = rewardAfter - rewardBefore;
        uint256 expectedReward = REWARD_RATE * 15 days;

        console.log("Staking Amount:", STAKING_AMOUNT);
        console.log("Reward Rate:", REWARD_RATE);
        console.log("Time Elapsed:", block.timestamp - startTime);
        console.log("Actual Reward:", actualReward);
        console.log("Expected Reward:", expectedReward);

        assertApproxEqRel(actualReward, expectedReward, 1e16); // Allow 1% deviation
    }

    function testRewardAccrual() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // 30-day tier

        uint256 startTime = block.timestamp;
        vm.warp(block.timestamp + 1 days);

        uint256 expectedReward = (REWARD_RATE * 1 days);
        uint256 actualReward = staking.pendingReward(alice, 0);

        console.log("Staking Amount:", STAKING_AMOUNT);
        console.log("Reward Rate:", REWARD_RATE);
        console.log("Time Elapsed:", block.timestamp - startTime);
        console.log("Actual Reward:", actualReward);
        console.log("Expected Reward:", expectedReward);

        assertApproxEqRel(actualReward, expectedReward, 1e16); // Allow 1% deviation
    }

    function testStakingCap() public {
        uint256 cap = 1500 * 1e18;
        staking.setStakingCap(cap);

        vm.prank(alice);
        staking.stake(1000 * 1e18, 0);

        vm.prank(bob);
        staking.stake(400 * 1e18, 0);

        vm.prank(bob);
        vm.expectRevert("Staking cap reached");
        staking.stake(101 * 1e18, 0);
    }

    function testRewardRateChange() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0);

        vm.warp(block.timestamp + 1 days);

        uint256 rewardBefore = staking.pendingReward(alice, 0);

        uint256 newRate = REWARD_RATE * 2;
        staking.setRewardRate(newRate);

        vm.warp(block.timestamp + 1 days);

        uint256 rewardAfter = staking.pendingReward(alice, 0);

        assertTrue(rewardAfter - rewardBefore > REWARD_RATE * 1 days);
    }

    function testMultipleTiers() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 0); // 30-day tier

        vm.prank(bob);
        staking.stake(STAKING_AMOUNT, 2); // 180-day tier

        vm.warp(block.timestamp + 30 days);

        uint256 aliceReward = staking.pendingReward(alice, 0);
        uint256 bobReward = staking.pendingReward(bob, 0);

        // Bob's reward should be approximately 3 times Alice's due to the 3x multiplier
        assertApproxEqRel(bobReward, aliceReward * 3, 1e16); // Allow 1% deviation
    }

    function testGetStakeInfo() public {
        vm.prank(alice);
        staking.stake(STAKING_AMOUNT, 1); // 90-day tier

        vm.warp(block.timestamp + 45 days);

        (
            uint256 amount,
            uint256 startTime,
            uint256 endTime,
            uint256 pendingReward
        ) = staking.getStakeInfo(alice, 0);

        assertEq(amount, STAKING_AMOUNT);
        assertTrue(startTime > 0);
        assertEq(endTime, startTime + 90 days);
        assertTrue(pendingReward > 0);
    }

    function testGetUserStakeCount() public {
        vm.startPrank(alice);
        staking.stake(STAKING_AMOUNT / 2, 0);
        staking.stake(STAKING_AMOUNT / 2, 1);
        vm.stopPrank();

        assertEq(staking.getUserStakeCount(alice), 2);
    }

    function testGetActiveTierCount() public {
        assertEq(staking.getActiveTierCount(), 3); // We added 3 tiers in setUp
    }

    function testRecoverERC20() public {
        uint256 amount = 100 * 1e18;
        rewardToken.transfer(address(staking), amount); // Transfer tokens to the contract first

        uint256 balanceBefore = rewardToken.balanceOf(owner);
        staking.recoverERC20(address(rewardToken), amount);
        uint256 balanceAfter = rewardToken.balanceOf(owner);

        assertEq(balanceAfter - balanceBefore, amount);
    }

    function testCannotRecoverStakingToken() public {
        vm.expectRevert("Cannot withdraw staking token");
        staking.recoverERC20(address(lpToken), 100);
    }
}
