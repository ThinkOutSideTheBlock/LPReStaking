// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TieredLPStaking
 * @dev A staking contract with tiered rewards for LP tokens
 */
contract TieredLPStaking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct Stake {
        uint256 amount;
        uint256 startTime;
        uint256 endTime;
        uint256 lastUpdateTime;
        uint256 rewardDebt;
    }

    struct Tier {
        uint256 duration;
        uint256 rewardMultiplier;
    }

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;

    Tier[] public tiers;
    mapping(address => Stake[]) public userStakes;

    uint256 public totalStaked;
    uint256 public rewardPerSecond;
    uint256 public lastUpdateTime;
    uint256 public accRewardPerShare;
    uint256 public stakingCap;

    uint256 private constant PRECISION = 1e12;
    uint256 private constant MAX_TIERS = 5;
    uint256 private constant EMERGENCY_WITHDRAW_FEE = 10; // 10%

    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 reward);
    event EmergencyWithdraw(address indexed user, uint256 amount, uint256 fee);
    event TierAdded(uint256 duration, uint256 rewardMultiplier);
    event StakingCapUpdated(uint256 newCap);
    event RewardRateUpdated(uint256 newRate);

    constructor(address _lpToken, address _rewardToken) Ownable(msg.sender) {
        require(
            _lpToken != address(0) && _rewardToken != address(0),
            "Invalid token addresses"
        );
        lpToken = IERC20(_lpToken);
        rewardToken = IERC20(_rewardToken);
    }

    function addTier(
        uint256 duration,
        uint256 rewardMultiplier
    ) external onlyOwner {
        require(tiers.length < MAX_TIERS, "Max tiers reached");
        require(
            duration > 0 && rewardMultiplier > 0,
            "Invalid tier parameters"
        );
        tiers.push(Tier(duration, rewardMultiplier));
        emit TierAdded(duration, rewardMultiplier);
    }

    function setStakingCap(uint256 _stakingCap) external onlyOwner {
        stakingCap = _stakingCap;
        emit StakingCapUpdated(_stakingCap);
    }

    function setRewardRate(uint256 _rewardPerSecond) external onlyOwner {
        updatePool();
        rewardPerSecond = _rewardPerSecond;
        emit RewardRateUpdated(_rewardPerSecond);
    }

    function stake(uint256 amount, uint256 tierIndex) external nonReentrant {
        require(amount > 0, "Cannot stake 0");
        require(tierIndex < tiers.length, "Invalid tier");
        require(totalStaked + amount <= stakingCap, "Staking cap reached");

        updatePool();

        if (userStakes[msg.sender].length > 0) {
            harvestRewards();
        }

        totalStaked += amount;
        Tier memory selectedTier = tiers[tierIndex];
        userStakes[msg.sender].push(
            Stake({
                amount: amount,
                startTime: block.timestamp,
                endTime: block.timestamp + selectedTier.duration,
                lastUpdateTime: block.timestamp,
                rewardDebt: (amount * accRewardPerShare) / PRECISION
            })
        );

        lpToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount, selectedTier.duration);
    }

    function unstake(uint256 index) external nonReentrant {
        require(index < userStakes[msg.sender].length, "Invalid stake index");
        Stake storage userStake = userStakes[msg.sender][index];
        require(
            block.timestamp >= userStake.endTime,
            "Staking period not ended"
        );

        updatePool();
        uint256 reward = pendingReward(msg.sender, index);
        uint256 amount = userStake.amount;

        totalStaked -= amount;
        delete userStakes[msg.sender][index];

        if (reward > 0) {
            rewardToken.safeTransfer(msg.sender, reward);
        }
        lpToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, reward);
    }

    function emergencyWithdraw(uint256 index) external nonReentrant {
        require(index < userStakes[msg.sender].length, "Invalid stake index");
        Stake storage userStake = userStakes[msg.sender][index];

        uint256 amount = userStake.amount;
        uint256 fee = (amount * EMERGENCY_WITHDRAW_FEE) / 100;
        uint256 amountToReturn = amount - fee;

        totalStaked -= amount;
        delete userStakes[msg.sender][index];

        lpToken.safeTransfer(msg.sender, amountToReturn);
        lpToken.safeTransfer(owner(), fee);

        emit EmergencyWithdraw(msg.sender, amountToReturn, fee);
    }

    function claimRewards() external nonReentrant {
        updatePool();
        uint256 reward = harvestRewards();
        if (reward > 0) {
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    function pendingReward(
        address user,
        uint256 index
    ) public view returns (uint256) {
        require(index < userStakes[user].length, "Invalid stake index");
        Stake storage userStake = userStakes[user][index];

        uint256 _accRewardPerShare = accRewardPerShare;
        if (totalStaked > 0) {
            uint256 timeElapsed = block.timestamp - lastUpdateTime;
            _accRewardPerShare +=
                (timeElapsed * rewardPerSecond * PRECISION) /
                totalStaked;
        }

        uint256 tierMultiplier = getTierMultiplier(
            userStake.endTime - userStake.startTime
        );

        return
            (((userStake.amount * _accRewardPerShare) /
                PRECISION -
                userStake.rewardDebt) * tierMultiplier) / PRECISION;
    }

    function getTotalStakedAmount(
        address account
    ) external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < userStakes[account].length; i++) {
            total += userStakes[account][i].amount;
        }
        return total;
    }

    function getStakeInfo(
        address account,
        uint256 index
    ) external view returns (uint256, uint256, uint256, uint256) {
        require(index < userStakes[account].length, "Invalid stake index");
        Stake storage stakeInfo = userStakes[account][index];
        return (
            stakeInfo.amount,
            stakeInfo.startTime,
            stakeInfo.endTime,
            pendingReward(account, index)
        );
    }

    function updatePool() internal {
        if (block.timestamp <= lastUpdateTime) {
            return;
        }
        if (totalStaked == 0) {
            lastUpdateTime = block.timestamp;
            return;
        }
        uint256 timeElapsed = block.timestamp - lastUpdateTime;
        uint256 reward = timeElapsed * rewardPerSecond;
        accRewardPerShare += (reward * PRECISION) / totalStaked;
        lastUpdateTime = block.timestamp;
    }

    function harvestRewards() internal returns (uint256 totalReward) {
        uint256[] memory rewards = new uint256[](userStakes[msg.sender].length);
        for (uint256 i = 0; i < userStakes[msg.sender].length; i++) {
            Stake storage stakeInfo = userStakes[msg.sender][i];
            uint256 reward = pendingReward(msg.sender, i);
            if (reward > 0) {
                rewards[i] = reward;
                totalReward += reward;
                stakeInfo.rewardDebt =
                    (stakeInfo.amount * accRewardPerShare) /
                    PRECISION;
                stakeInfo.lastUpdateTime = block.timestamp > stakeInfo.endTime
                    ? stakeInfo.endTime
                    : block.timestamp;
            }
        }
        if (totalReward > 0) {
            for (uint256 i = 0; i < rewards.length; i++) {
                if (rewards[i] > 0) {
                    userStakes[msg.sender][i].rewardDebt +=
                        (rewards[i] * PRECISION) /
                        userStakes[msg.sender][i].amount;
                }
            }
        }
    }

    function getTierMultiplier(
        uint256 duration
    ) internal view returns (uint256) {
        for (uint256 i = 0; i < tiers.length; i++) {
            if (tiers[i].duration == duration) {
                return tiers[i].rewardMultiplier;
            }
        }
        return PRECISION; // Default multiplier (1x) if no matching tier found
    }

    function getUserStakeCount(address user) external view returns (uint256) {
        return userStakes[user].length;
    }

    function getActiveTierCount() external view returns (uint256) {
        return tiers.length;
    }

    // Emergency function to recover wrongly sent tokens
    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner {
        require(
            tokenAddress != address(lpToken),
            "Cannot withdraw staking token"
        );
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
    }
}
