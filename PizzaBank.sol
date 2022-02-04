//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./libraries/BoringERC20.sol";

// Adapted from MasterChefJoeV2 and Police And Thieves Vault
contract PizzaBank is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using BoringERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 lastRewardTimestamp; // Last timestamp that Reward distribution occurs.
        uint256 accRewardTokenPerShare; // Accumulated Reward per share, times 1e12. See below.
    }

    IERC20 public rewardToken;
    // Reward tokens created per second.
    uint256 public rewardPerSecond;

    // Info of pool.
    PoolInfo public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (address => UserInfo) public userInfo;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event UpdatePool(uint256 lastRewardTimestamp, uint256 lpSupply, uint256 accRewardTokenPerShare);
    event Harvest(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event DepositRewards(uint256 amount);
    event EmergencyRewardWithdraw(address indexed user, uint256 amount);

    constructor(
        IERC20 _stakeToken,
        IERC20 _rewardToken,
        uint256 _rewardPerSecond,
        uint256 _startTimestamp
    ) {
        rewardToken = _rewardToken;
        rewardPerSecond = _rewardPerSecond;

        poolInfo = PoolInfo({
                lpToken: _stakeToken,
                lastRewardTimestamp: _startTimestamp,
                accRewardTokenPerShare: 0
            });
    }

    // View function to see pending Token on frontend.
    function pendingRewards(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 accRewardTokenPerShare = poolInfo.accRewardTokenPerShare;
        uint256 lpSupply = poolInfo.lpToken.balanceOf(address(this));
        if (block.timestamp > poolInfo.lastRewardTimestamp && lpSupply != 0) {
            uint256 multiplier = block.timestamp.sub(poolInfo.lastRewardTimestamp);
            uint256 tokenReward = multiplier.mul(rewardPerSecond);
            accRewardTokenPerShare = accRewardTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accRewardTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool() public whenNotPaused {
        if (block.timestamp <= poolInfo.lastRewardTimestamp) {
            return;
        }
        uint256 lpSupply = poolInfo.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            poolInfo.lastRewardTimestamp = block.timestamp;
            return;
        }
        uint256 multiplier = block.timestamp.sub(poolInfo.lastRewardTimestamp);
        uint256 tokenReward = multiplier.mul(rewardPerSecond);
        poolInfo.accRewardTokenPerShare = poolInfo.accRewardTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        poolInfo.lastRewardTimestamp = block.timestamp;
        emit UpdatePool(poolInfo.lastRewardTimestamp, lpSupply, poolInfo.accRewardTokenPerShare);
    }

    // Deposit LP tokens to MasterChef for Reward allocation.
    function deposit(uint256 _amount) public whenNotPaused nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        updatePool();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(poolInfo.accRewardTokenPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeTokenTransfer(msg.sender, pending);
            }
            emit Harvest(msg.sender, pending);
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(poolInfo.accRewardTokenPerShare).div(1e12);

        if(_amount > 0) {
            poolInfo.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }
        emit Deposit(msg.sender, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _amount) public whenNotPaused nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool();

        // Harvest Reward
        uint256 pending = user.amount.mul(poolInfo.accRewardTokenPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeTokenTransfer(msg.sender, pending);
        }
        emit Harvest(msg.sender, pending);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(poolInfo.accRewardTokenPerShare).div(1e12);

        if(_amount > 0) {
            poolInfo.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        emit Withdraw(msg.sender, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw() public nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        poolInfo.lpToken.safeTransfer(address(msg.sender), user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        emit EmergencyWithdraw(msg.sender, user.amount);
    }

    // Safe Reward transfer function, just in case if rounding error causes pool to not have enough Reward.
    function safeTokenTransfer(address _to, uint256 _amount) internal {
        uint256 rewardBal = rewardToken.balanceOf(address(this));
        if (_amount > rewardBal) {
            rewardToken.safeTransfer(_to, rewardBal);
        } else {
            rewardToken.safeTransfer(_to, _amount);
        }
    }

    function depositRewards(uint256 _amount) external {
        require(_amount > 0, 'Deposit value must be greater than 0.');
        rewardToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        emit DepositRewards(_amount);
    }

    // Withdraw reward. EMERGENCY ONLY.
    function emergencyRewardWithdraw(uint256 _amount) external onlyOwner {
        require(_amount <= rewardToken.balanceOf(address(this)), 'not enough rewards');
        // Withdraw rewards
        rewardToken.safeTransfer(address(msg.sender), _amount);
        emit EmergencyRewardWithdraw(msg.sender, _amount);
    }

    // enables owner to pause / unpause minting
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }
}