//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./Chef.sol";
import "./Upgrade.sol";
import "./Pizza.sol";
import "./PizzeriaProgression.sol";

contract Pizzeria is PizzeriaProgression, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    // Constants
    uint256 public constant YIELD_PPS = 16666666666666667; // pizza baked per second per unit of yield
    uint256 public constant CLAIM_PIZZA_CONTRIBUTION_PERCENTAGE = 10;
    uint256 public constant CLAIM_PIZZA_BURN_PERCENTAGE = 10;
    uint256 public constant MAX_FATIGUE = 100000000000000;

    uint256 public startTime;

    // Staking

    struct StakedChef {
        address owner;
        uint256 tokenId;
        uint256 startTimestamp;
        bool staked;
    }

    struct StakedChefInfo {
        uint256 chefId;
        uint256 upgradeId;
        uint256 pizza;
        uint256 fatigue;
        uint256 timeUntilFatigued;
    }

    mapping(uint256 => StakedChef) public stakedChefs; // tokenId => StakedChef
    mapping(address => mapping(uint256 => uint256)) private ownedChefStakes; // (address, index) => stake
    mapping(uint256 => uint256) private ownedChefStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedChefStakesBalance; // address => stake count

    mapping(uint256 => uint256) public ownedUpgradeByChef; // chef tokenId => upgrade tokenId

    mapping(address => uint256) public fatiguePerMinute; // address => fatigue per minute in the pizzeria
    mapping(uint256 => uint256) private chefFatigue; // tokenId => fatigue
    mapping(uint256 => uint256) private chefPizza; // tokenId => pizza

    mapping(address => uint256[2]) private numberOfChefs; // address => [number of regular chefs, number of master chefs]
    mapping(address => uint256) private totalPPM; // address => total PPM


    // Fatigue cooldowns

    struct RestingChef {
        address owner;
        uint256 tokenId;
        uint256 endTimestamp;
        bool present;
    }

    struct RestingChefInfo {
        uint256 tokenId;
        uint256 endTimestamp;
    }
    
    mapping(uint256 => RestingChef) public restingChefs; // tokenId => RestingChef
    mapping(address => mapping(uint256 => uint256)) private ownedRestingChefs; // (user, index) => resting chef id
    mapping(uint256 => uint256) private restingChefsIndex; // tokenId => index in its owner's cooldown list
    mapping(address => uint256) public restingChefsBalance; // address => cooldown count

    // Var

    Chef public chef;
    Upgrade public upgrade;
    Pizza public pizza;
    address public freezerAddress;
    
    constructor(Chef _chef, Upgrade _upgrade, Pizza _pizza, Soda _soda, address _freezerAddress) PizzeriaProgression (_soda) {
        chef = _chef;
        upgrade = _upgrade;
        pizza = _pizza;
        freezerAddress = _freezerAddress;
    }

    // Views

    function _getUpgradeStakedForChef(uint256 _chefId) internal view returns (uint256) {
        return ownedUpgradeByChef[_chefId];
    }

    function _getFatiguePerMinuteWithModifier(address _owner) internal view returns (uint256) {
        uint256 fatigueSkillModifier = _getFatigueSkillModifier(_owner);
        return fatiguePerMinute[_owner].mul(fatigueSkillModifier).div(100);
    }

    function _getMasterChefNumber(address _owner) internal view returns (uint256) {
        return numberOfChefs[_owner][1];
    }

    /**
     * Returns the current chef's fatigue
     */
    function getFatigueAccruedForChef(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(stakedChef.owner == _msgSender(), "You don't own this token");
        }

        uint256 fatigue = (block.timestamp - stakedChef.startTimestamp) * _getFatiguePerMinuteWithModifier(stakedChef.owner);
        fatigue += chefFatigue[_tokenId];
        if (fatigue > MAX_FATIGUE) {
            fatigue = MAX_FATIGUE;
        }
        return fatigue;
    }

    /**
     * Returns the timestamp of when the chef will be fatigued
     */
    function getTimeUntilFatigued(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(stakedChef.owner == _msgSender(), "You don't own this token");
        }

        return stakedChef.startTimestamp + 60 * ( MAX_FATIGUE - chefFatigue[_tokenId] ) / _getFatiguePerMinuteWithModifier(stakedChef.owner); 
    }

    /**
     * Returns the timestamp of when the chef will be fully rested
     */
    function _getRestingTime(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(stakedChef.owner == _msgSender(), "You don't own this token");
        }

        uint256 maxTime = 43200; //12*60*60
        uint256 chefType = chef.getType(_tokenId);
        if( chefType == chef.MASTER_CHEF_TYPE()){
            maxTime = maxTime / 2; // master chefs rest half of the time of regular chefs
        }

        uint256 fatigue = getFatigueAccruedForChef(_tokenId, false);
        if(fatigue > MAX_FATIGUE / 2){
            return maxTime * fatigue / MAX_FATIGUE;
        }

        return maxTime / 2; // minimum rest time is half of the maximum time
    }

    function getPizzaAccruedForManyChefs(uint256[] calldata _tokenIds) public view returns (uint256[] memory) {
        uint256[] memory output = new uint256[](_tokenIds.length);
        for (uint256 i = 0; i < _tokenIds.length; i++) {
            output[i] = _getPizzaAccruedForChef(_tokenIds[i], false);
        }
        return output;
    }

    /**
     * Returns chef's pizza from chefPizza mapping
     */
    function _getPizzaAccruedForChef(uint256 _tokenId, bool checkOwnership) internal view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        address owner = stakedChef.owner;
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(owner == _msgSender(), "You don't own this token");
        }

        // if chefFatigue = 1 it means that chefPizza already has the correct value for the pizza, since it didn't produce pizza since last update
        if(chefFatigue[_tokenId] == 1){
            return chefPizza[_tokenId];
        }

        uint256 modifiedFatiguePerMinute = _getFatiguePerMinuteWithModifier(owner);
        uint256 timeUntilFatigued = getTimeUntilFatigued(_tokenId, false);

        uint256 endTimestamp;
        if(block.timestamp >= timeUntilFatigued){
            endTimestamp = timeUntilFatigued;
        } else {
            endTimestamp = block.timestamp;
        }

        uint256 ppm;
        uint256 upgradeId = _getUpgradeStakedForChef(_tokenId);

        if(upgradeId > 0){
            ppm = (chef.getYield(_tokenId) + upgrade.getYield(upgradeId) ) * YIELD_PPS;
        } else {
            ppm = chef.getYield(_tokenId) * YIELD_PPS;
        }

        uint256 masterChefSkillModifier = _getMasterChefSkillModifier(owner, _getMasterChefNumber(owner));
        ppm = ppm * masterChefSkillModifier / 100;

        uint256 delta = endTimestamp - stakedChef.startTimestamp;

        uint256 pizzaAccruedForChef = delta * ppm * (MAX_FATIGUE - chefFatigue[_tokenId]) / (MAX_FATIGUE);
        pizzaAccruedForChef -= delta * delta * ppm * modifiedFatiguePerMinute / (2 * MAX_FATIGUE);

        return chefPizza[_tokenId] + pizzaAccruedForChef;
    }

    /**
     * Calculates the total PPM staked for a pizzeria. 
     * This will also be used in the fatiguePerMinute calculation
     */
    function getTotalPPM(address _owner) public view returns (uint256) {
        return totalPPM[_owner];
    }

    function gameStarted() public view returns (bool) {
        return startTime != 0 && block.timestamp >= startTime;
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        require(!gameStarted(), "game already started");
        startTime = _startTime;
    }

    /**
     * Updates the Fatigue per Minute
     * This function is called in _updateState
     */

    function fatiguePerMinuteCalculation(uint256 ppm) public pure returns (uint256) {
        // NOTE: fatiguePerMinute[_owner] = 8610000000 + 166000000  * totalPPM[_owner] + -220833 * totalPPM[_owner]* totalPPM[_owner]  + 463 * totalPPM[_owner]*totalPPM[_owner]*totalPPM[_owner]; 
        uint256 a = 463;
        uint256 b = 220833;
        uint256 c = 166000000;
        uint256 d = 8610000000;
        if(ppm == 0){
            return d;
        }
        return d + c * ppm + a * ppm * ppm * ppm - b * ppm * ppm;
    }

    function _updatefatiguePerMinute(address _owner) internal {
        fatiguePerMinute[_owner] = fatiguePerMinuteCalculation(totalPPM[_owner]);
    }

    /**
     * This function updates chefPizza and chefFatigue mappings
     * Calls _updatefatiguePerMinute
     * Also updates startTimestamp for chefs
     * It should be used whenever the PPM changes
     */
    function _updateState(address _owner) internal {
        uint256 chefBalance = ownedChefStakesBalance[_owner];
        for (uint256 i = 0; i < chefBalance; i++) {
            uint256 tokenId = ownedChefStakes[_owner][i];
            StakedChef storage stakedChef = stakedChefs[tokenId];
            if (stakedChef.staked) {
                chefPizza[tokenId] = _getPizzaAccruedForChef(tokenId, false);

                chefFatigue[tokenId] = getFatigueAccruedForChef(tokenId, false);

                stakedChef.startTimestamp = block.timestamp;
            }
        }
        _updatefatiguePerMinute(_owner);
    }

    //Claim
    function claimPizza() public {
        uint256 totalClaimed = 0;

        address owner = _msgSender();

        uint256 freezerSkillModifier = _getFreezerSkillModifier(owner);
        uint256 burnSkillModifier = _getBurnSkillModifier(owner);

        uint256 chefBalance = ownedChefStakesBalance[owner];

        for (uint256 i = 0; i < chefBalance; i++) {
            uint256 chefId = ownedChefStakes[owner][i];

            totalClaimed += _getPizzaAccruedForChef(chefId, true); // also checks that msg.sender owns this token

            delete chefPizza[chefId];

            stakedChefs[chefId].startTimestamp = block.timestamp;
        }

        uint256 taxAmountFreezer = totalClaimed * (CLAIM_PIZZA_CONTRIBUTION_PERCENTAGE - freezerSkillModifier) / 100;
        uint256 taxAmountBurn = totalClaimed * (CLAIM_PIZZA_BURN_PERCENTAGE - burnSkillModifier) / 100;

        totalClaimed = totalClaimed - taxAmountFreezer - taxAmountBurn;

        pizza.mint(_msgSender(), totalClaimed);
        pizza.mint(freezerAddress, taxAmountFreezer);
    }

    function unstakeChefsAndUpgrades(uint256[] calldata _chefIds, uint256[2][] calldata _upgradeIds) public nonReentrant {
        claimPizza();

        address owner = _msgSender();
        
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //unstake upgrades
            uint256 upgradeId = _upgradeIds[0][i];
            uint256 chefId = _upgradeIds[1][i];

            require(upgrade.ownerOf(upgradeId) == owner, "You don't own this upgrade");
            require(chef.ownerOf(chefId) == owner, "You don't own this chef");
            require(stakedChefs[chefId].staked, "Chef needs to be staked");

            _removeUpgradeFromChef(upgradeId, chefId);
            totalPPM[owner] -= upgrade.getYield(upgradeId);
            upgrade.transferFrom(address(this), owner, upgradeId);
        }

        for (uint256 i = 0; i < _chefIds.length; i++) { //unstake chefs and the ugprades they hold
            uint256 chefId = _chefIds[i];

            require(chef.ownerOf(chefId) == owner, "You don't own this token");
            require(stakedChefs[chefId].staked, "Chef needs to be staked");

            if(chef.getType(chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfChefs[owner][1]--; 
            } else {
                numberOfChefs[owner][0]--; 
            }

            totalPPM[owner] -= chef.getYield(chefId);

            uint256 upgradeId = _getUpgradeStakedForChef(chefId);
            if(upgradeId > 0){
                totalPPM[owner] -= upgrade.getYield(upgradeId);
                _removeUpgradeFromChef(upgradeId, chefId);
                upgrade.transferFrom(address(this), owner, upgradeId);
            }

            _moveChefToCooldown(chefId);
        }

        _updateState(owner);
    }

    // Stake

     /**
     * This function updates stake chefs and upgrades
     * The upgrades are paired with the chef the upgrade will be applied
     */
    function stakeMany(uint256[] calldata _chefIds, uint256[2][] calldata _upgradeIds) public nonReentrant {
        require(gameStarted(), "The game has not started");

        address owner = _msgSender();

        uint256 maxNumberChefs = _getMaxNumberChefs(owner);
        uint256 chefsAfterStaking = _chefIds.length + numberOfChefs[owner][0] + numberOfChefs[owner][1];
        require(maxNumberChefs >= chefsAfterStaking, "You can't stake that many chefs");

        for (uint256 i = 0; i < _chefIds.length; i++) { //stakes chef
            uint256 chefId = _chefIds[i];

            require(chef.ownerOf(chefId) == owner, "You don't own this token");
            require(chef.getType(chefId) > 0, "Chef not yet revealed");
            require(!stakedChefs[chefId].staked, "Chef is already staked");

            _addChefToPizzeria(chefId, owner);

            if(chef.getType(chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfChefs[owner][1]++; 
            } else {
                numberOfChefs[owner][0]++; 
            }

            totalPPM[owner] += chef.getYield(chefId);

            chef.transferFrom(owner, address(this), chefId);
        }

        uint256 maxLevelUpgrade = _getMaxLevelUpgrade(owner);
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //stakes upgrades
            uint256 upgradeId = _upgradeIds[0][i];
            uint256 chefId = _upgradeIds[1][i];

            require(upgrade.ownerOf(upgradeId) == owner, "You don't own this upgrade");
            require(upgrade.getLevel(upgradeId) <= maxLevelUpgrade, "You can't equip that upgrade");
            require(chef.ownerOf(chefId) == owner, "You don't own this chef");
            require(chef.getType(chefId) > 0, "Chef not yet revealed");
            require(stakedChefs[chefId].staked, "Chef needs to be staked");

            upgrade.transferFrom(owner, address(this), upgradeId);
            _addUpgradeToChef(upgradeId, chefId); 
            totalPPM[owner] += upgrade.getYield(upgradeId);
        }
        _updateState(owner);
    }

    function _addChefToPizzeria(uint256 _tokenId, address _owner) internal {
        stakedChefs[_tokenId] = StakedChef({
            owner: _owner,
            tokenId: _tokenId,
            startTimestamp: block.timestamp,
            staked: true
        });
        _addStakeToOwnerEnumeration(_owner, _tokenId);
    }

    function _addStakeToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = ownedChefStakesBalance[_owner];
        ownedChefStakes[_owner][length] = _tokenId;
        ownedChefStakesIndex[_tokenId] = length;
        ownedChefStakesBalance[_owner]++;
    }


    function _addUpgradeToChef(uint256 _upgradeId, uint256 _chefId) internal {
        require(ownedUpgradeByChef[_chefId] == 0, "Chef can't hold two upgrades");
        ownedUpgradeByChef[_chefId] = _upgradeId;
    }

    // Unstake
    function _removeUpgradeFromChef(uint256 _upgradeId, uint256 _chefId) internal {
        require(ownedUpgradeByChef[_chefId] == _upgradeId, "The chef is not holding this upgrade.");
        delete ownedUpgradeByChef[_chefId];
    }

    // Cooldown
    function _moveChefToCooldown(uint256 _chefId) internal {
        address owner = stakedChefs[_chefId].owner;

        uint256 endTimestamp = block.timestamp + _getRestingTime(_chefId, false);
        restingChefs[_chefId] = RestingChef({
            owner: owner,
            tokenId: _chefId,
            endTimestamp: endTimestamp,
            present: true
        });

        delete chefFatigue[_chefId];
        delete stakedChefs[_chefId];
        _removeStakeFromOwnerEnumeration(owner, _chefId);
        _addCooldownToOwnerEnumeration(owner, _chefId);
    }

    function withdrawChefs(uint256[] calldata _chefIds) public {
        for (uint256 i = 0; i < _chefIds.length; i++) {
            uint256 _chefId = _chefIds[i];
            RestingChef memory resting = restingChefs[_chefId];

            require(resting.present, "Chef is not resting");
            require(resting.owner == _msgSender(), "You don't own this chef");
            require(block.timestamp >= resting.endTimestamp, "Chef is still resting");

            _removeChefFromCooldown(_chefId);
            chef.transferFrom(address(this), _msgSender(), _chefId);
        }
    }

    function _addCooldownToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = restingChefsBalance[_owner];
        ownedRestingChefs[_owner][length] = _tokenId;
        restingChefsIndex[_tokenId] = length;
        restingChefsBalance[_owner]++;
    }

    function _removeStakeFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = ownedChefStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedChefStakesIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedChefStakes[_owner][lastTokenIndex];

            ownedChefStakes[_owner][tokenIndex] = lastTokenId;
            ownedChefStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedChefStakesIndex[_tokenId];
        delete ownedChefStakes[_owner][lastTokenIndex];
        ownedChefStakesBalance[_owner]--;
    }

    function _removeChefFromCooldown(uint256 _chefId) internal {
        address owner = restingChefs[_chefId].owner;
        delete restingChefs[_chefId];
        _removeCooldownFromOwnerEnumeration(owner, _chefId);
    }

    function _removeCooldownFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = restingChefsBalance[_owner] - 1;
        uint256 tokenIndex = restingChefsIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedRestingChefs[_owner][lastTokenIndex];
            ownedRestingChefs[_owner][tokenIndex] = lastTokenId;
            restingChefsIndex[lastTokenId] = tokenIndex;
        }

        delete restingChefsIndex[_tokenId];
        delete ownedRestingChefs[_owner][lastTokenIndex];
        restingChefsBalance[_owner]--;
    }

    function stakeOfOwnerByIndex(address _owner, uint256 _index) public view returns (uint256) {
        require(_index < ownedChefStakesBalance[_owner], "owner index out of bounds");
        return ownedChefStakes[_owner][_index];
    }

    function batchedStakesOfOwner(
        address _owner,
        uint256 _offset,
        uint256 _maxSize
    ) public view returns (StakedChefInfo[] memory) {
        if (_offset >= ownedChefStakesBalance[_owner]) {
            return new StakedChefInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= ownedChefStakesBalance[_owner]) {
            outputSize = ownedChefStakesBalance[_owner] - _offset;
        }
        StakedChefInfo[] memory outputs = new StakedChefInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 chefId = stakeOfOwnerByIndex(_owner, _offset + i);
            uint256 upgradeId = _getUpgradeStakedForChef(chefId);

            outputs[i] = StakedChefInfo({
                chefId: chefId,
                upgradeId: upgradeId,
                pizza: _getPizzaAccruedForChef(chefId, false),
                fatigue: getFatigueAccruedForChef(chefId, false),
                timeUntilFatigued: getTimeUntilFatigued(chefId, false)
            });
        }

        return outputs;
    }


    function cooldownOfOwnerByIndex(address _owner, uint256 _index) public view returns (uint256) {
        require(_index < restingChefsBalance[_owner], "owner index out of bounds");
        return ownedRestingChefs[_owner][_index];
    }

    function batchedCooldownsOfOwner(
        address _owner,
        uint256 _offset,
        uint256 _maxSize
    ) public view returns (RestingChefInfo[] memory) {
        if (_offset >= restingChefsBalance[_owner]) {
            return new RestingChefInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= restingChefsBalance[_owner]) {
            outputSize = restingChefsBalance[_owner] - _offset;
        }
        RestingChefInfo[] memory outputs = new RestingChefInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 tokenId = cooldownOfOwnerByIndex(_owner, _offset + i);

            outputs[i] = RestingChefInfo({
                tokenId: tokenId,
                endTimestamp: restingChefs[tokenId].endTimestamp
            });
        }

        return outputs;
    }


}