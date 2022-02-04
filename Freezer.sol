//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./Pizza.sol";

contract Freezer is ERC20("Staked Pizza", "sPIZZA"), Ownable {
    using SafeERC20 for Pizza;
    using SafeMath for uint256;

    uint256 public constant DELAYED_UNSTAKE_LOCKUP_PERIOD = 2 days;
    uint256 public constant DELAYED_UNSTAKE_BURN_PERCENT = 10;
    uint256 public constant QUICK_UNSTAKE_CONTRIBUTION_PERCENT = 50;
    uint256 public constant QUICK_UNSTAKE_BURN_PERCENT = 25;

    Pizza public pizza;
    uint256 public frozenPizza; // PIZZA pending withdrawal

    mapping(address => uint256) public unlockAmounts;
    mapping(address => uint256) public unlockTimestamps;

    constructor(Pizza _pizza) {
        pizza = _pizza;
    }

    // Views

    function pizzaBalance() public view returns (uint256 balance) {
        return pizza.balanceOf(address(this)) - frozenPizza;
    }

    function _unstakeOutput(uint256 _share) internal view returns (uint256 output) {
        uint256 totalShares = totalSupply();
        return _share.mul(pizzaBalance()).div(totalShares);
    }

    // External

    function stake(uint256 _amount) external {
        uint256 totalShares = totalSupply();
        // If no sPIZZA exists, mint it 1:1 to the amount put in
        if (totalShares == 0 || pizzaBalance() == 0) {
            _mint(_msgSender(), _amount);
        } else {
            uint256 share = _amount.mul(totalShares).div(pizzaBalance());
            _mint(_msgSender(), share);
        }

        pizza.transferToFreezer(_msgSender(), _amount);
    }

    function quickUnstake(uint256 _share) external {
        // QUICK_UNSTAKE_CONTRIBUTION_PERCENT of the claimable PIZZA will remain in the freezer
        // the rest is transfered to the staker
        uint256 unstakeOutput = _unstakeOutput(_share);
        uint256 output = unstakeOutput.mul(100 - QUICK_UNSTAKE_CONTRIBUTION_PERCENT).div(100);
        // QUICK_UNSTAKE_BURN_PERCENT of the claimable PIZZA is burned
        uint256 amountSpoiled = unstakeOutput.mul(QUICK_UNSTAKE_BURN_PERCENT).div(100);

        // burn staker's share
        _burn(_msgSender(), _share);

        pizza.burn(address(this), amountSpoiled);
        pizza.safeTransfer(_msgSender(), output);
    }

    /**
     * @dev _share argument specified in sPIZZA
     */
    function prepareDelayedUnstake(uint256 _share) external {
        // calculate output and burn staker's share
        uint256 output = _unstakeOutput(_share);
        _burn(_msgSender(), _share);

        // calculate and burn amount of output spoiled
        uint256 amountSpoiled = output.mul(DELAYED_UNSTAKE_BURN_PERCENT).div(100);

        // remove amountSpoiled from output
        output -= amountSpoiled;

        unlockAmounts[_msgSender()] += output;
        unlockTimestamps[_msgSender()] = block.timestamp + DELAYED_UNSTAKE_LOCKUP_PERIOD;
        frozenPizza += output;

        pizza.burn(address(this), amountSpoiled);
    }

    /**
     * @dev argument specified in PIZZA, not sPIZZA
     */
    function claimDelayedUnstake(uint256 _amount) external {
        require(block.timestamp >= unlockTimestamps[_msgSender()], "PIZZA not yet unlocked");
        require(_amount <= unlockAmounts[_msgSender()], "insufficient locked balance");

        // deduct from unlocked
        unlockAmounts[_msgSender()] -= _amount;

        frozenPizza -= _amount;

        // transfer claim
        pizza.safeTransfer(_msgSender(), _amount);
    }
}
