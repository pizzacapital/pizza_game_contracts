//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./Chef.sol";
import "./Upgrade.sol";
import "./Pizza.sol";
import "./PizzeriaProgressionV2.sol";
import "./Pizzeria.sol";

contract PizzeriaV2 is PizzeriaProgressionV2, ReentrancyGuard {
    using SafeMath for uint256;

    // Constants
    uint256 public constant YIELD_PPS = 16666666666666667; // pizza cooked per second per unit of yield
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
        uint256 chefPPM;
        uint256 upgradePPM;
        uint256 pizza;
        uint256 fatigue;
        uint256 timeUntilFatigued;
    }

    mapping(uint256 => StakedChef) public stakedChefs; // tokenId => StakedChef
    mapping(address => mapping(uint256 => uint256)) private ownedChefStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) private ownedChefStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedChefStakesBalance; // address => stake count

    mapping(address => uint256) public fatiguePerMinute; // address => fatigue per minute in the pizzeria
    mapping(uint256 => uint256) private chefFatigue; // tokenId => fatigue
    mapping(uint256 => uint256) private chefPizza; // tokenId => pizza

    mapping(address => uint256[2]) private numberOfChefs; // address => [number of regular chefs, number of master chefs]
    mapping(address => uint256) private totalPPM; // address => total PPM

    struct StakedUpgrade {
        address owner;
        uint256 tokenId;
        bool staked;
    }

    mapping(uint256 => StakedUpgrade) public stakedUpgrades; // tokenId => StakedUpgrade
    mapping(address => mapping(uint256 => uint256)) private ownedUpgradeStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) private ownedUpgradeStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedUpgradeStakesBalance; // address => stake count

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
    
    constructor(Chef _chef, Upgrade _upgrade, Pizza _pizza, Soda _soda, address _freezerAddress) PizzeriaProgressionV2 (_soda) {
        chef = _chef;
        upgrade = _upgrade;
        pizza = _pizza;
        freezerAddress = _freezerAddress;
    }

    // Views

    function _getUpgradeStakedForChef(address _owner, uint256 _chefId) internal view returns (uint256) {
        uint256 index = ownedChefStakesIndex[_chefId];
        return ownedUpgradeStakes[_owner][index];
    }

    function getFatiguePerMinuteWithModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkillModifier = getFatigueSkillModifier(_owner);
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

        uint256 fatigue = (block.timestamp - stakedChef.startTimestamp) * getFatiguePerMinuteWithModifier(stakedChef.owner) / 60;
        fatigue += chefFatigue[_tokenId];
        if (fatigue > MAX_FATIGUE) {
            fatigue = MAX_FATIGUE;
        }
        return fatigue;
    }

    /**
     * Returns the timestamp of when the chef will be fatigued
     */
    function timeUntilFatiguedCalculation(uint256 _startTime, uint256 _fatigue, uint256 _fatiguePerMinute) public pure returns (uint256) {
        return _startTime + 60 * ( MAX_FATIGUE - _fatigue ) / _fatiguePerMinute;
    }

    function getTimeUntilFatigued(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(stakedChef.owner == _msgSender(), "You don't own this token");
        }
        return timeUntilFatiguedCalculation(stakedChef.startTimestamp, chefFatigue[_tokenId], getFatiguePerMinuteWithModifier(stakedChef.owner));
    }

    /**
     * Returns the timestamp of when the chef will be fully rested
     */
     function restingTimeCalculation(uint256 _chefType, uint256 _masterChefType, uint256 _fatigue) public pure returns (uint256) {
        uint256 maxTime = 43200; //12*60*60
        if( _chefType == _masterChefType){
            maxTime = maxTime / 2; // master chefs rest half of the time of regular chefs
        }

        if(_fatigue > MAX_FATIGUE / 2){
            return maxTime * _fatigue / MAX_FATIGUE;
        }

        return maxTime / 2; // minimum rest time is half of the maximum time
    }
    function getRestingTime(uint256 _tokenId, bool checkOwnership) public view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(stakedChef.owner == _msgSender(), "You don't own this token");
        }

        return restingTimeCalculation(chef.getType(_tokenId), chef.MASTER_CHEF_TYPE(), getFatigueAccruedForChef(_tokenId, false));
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
     function pizzaAccruedCalculation(uint256 _initialPizza, uint256 _deltaTime, uint256 _ppm, uint256 _modifier, uint256 _fatigue, uint256 _fatiguePerMinute) public pure returns (uint256) {
        if(_fatigue >= MAX_FATIGUE){
            return _initialPizza;
        }

        uint256 a = _deltaTime * _ppm * YIELD_PPS * _modifier * (MAX_FATIGUE - _fatigue) / ( 100 * MAX_FATIGUE);
        uint256 b = _deltaTime * _deltaTime * _ppm * YIELD_PPS * _modifier * _fatiguePerMinute / (100 * 2 * 60 * MAX_FATIGUE);
        if(a > b){
            return _initialPizza + a - b;
        }

        return _initialPizza;
    }
    function _getPizzaAccruedForChef(uint256 _tokenId, bool checkOwnership) internal view returns (uint256) {
        StakedChef memory stakedChef = stakedChefs[_tokenId];
        address owner = stakedChef.owner;
        require(stakedChef.staked, "This token isn't staked");
        if (checkOwnership) {
            require(owner == _msgSender(), "You don't own this token");
        }

        // if chefFatigue = MAX_FATIGUE it means that chefPizza already has the correct value for the pizza, since it didn't produce pizza since last update
        uint256 chefFatigueLastUpdate = chefFatigue[_tokenId];
        if(chefFatigueLastUpdate == MAX_FATIGUE){
            return chefPizza[_tokenId];
        }

        uint256 timeUntilFatigued = getTimeUntilFatigued(_tokenId, false);

        uint256 endTimestamp;
        if(block.timestamp >= timeUntilFatigued){
            endTimestamp = timeUntilFatigued;
        } else {
            endTimestamp = block.timestamp;
        }

        uint256 ppm = chef.getYield(_tokenId);
        uint256 upgradeId = _getUpgradeStakedForChef(owner, _tokenId);

        if(upgradeId > 0){
            ppm += upgrade.getYield(upgradeId);
        }

        uint256 masterChefSkillModifier = getMasterChefSkillModifier(owner, _getMasterChefNumber(owner));

        uint256 delta = endTimestamp - stakedChef.startTimestamp;

        return pizzaAccruedCalculation(chefPizza[_tokenId], delta, ppm, masterChefSkillModifier, chefFatigueLastUpdate, getFatiguePerMinuteWithModifier(owner));
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

    function fatiguePerMinuteCalculation(uint256 _ppm) public pure returns (uint256) {
        // NOTE: fatiguePerMinute[_owner] = 8610000000 + 166000000  * totalPPM[_owner] + -220833 * totalPPM[_owner]* totalPPM[_owner]  + 463 * totalPPM[_owner]*totalPPM[_owner]*totalPPM[_owner]; 
        uint256 a = 463;
        uint256 b = 220833;
        uint256 c = 166000000;
        uint256 d = 8610000000;
        if(_ppm == 0){
            return d;
        }
        return d + c * _ppm + a * _ppm * _ppm * _ppm - b * _ppm * _ppm;
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
            if (stakedChef.staked && block.timestamp > stakedChef.startTimestamp) {
                chefPizza[tokenId] = _getPizzaAccruedForChef(tokenId, false);

                chefFatigue[tokenId] = getFatigueAccruedForChef(tokenId, false);

                stakedChef.startTimestamp = block.timestamp;
            }
        }
        _updatefatiguePerMinute(_owner);
    }

    //Claim
    function _claimPizza(address _owner) internal {
        uint256 totalClaimed = 0;

        uint256 freezerSkillModifier = getFreezerSkillModifier(_owner);
        uint256 burnSkillModifier = getBurnSkillModifier(_owner);

        uint256 chefBalance = ownedChefStakesBalance[_owner];

        for (uint256 i = 0; i < chefBalance; i++) {
            uint256 chefId = ownedChefStakes[_owner][i];

            totalClaimed += _getPizzaAccruedForChef(chefId, true); // also checks that msg.sender owns this token

            delete chefPizza[chefId];

            chefFatigue[chefId] = getFatigueAccruedForChef(chefId, false); // bug fix for fatigue

            stakedChefs[chefId].startTimestamp = block.timestamp;
        }

        uint256 taxAmountFreezer = totalClaimed * (CLAIM_PIZZA_CONTRIBUTION_PERCENTAGE - freezerSkillModifier) / 100;
        uint256 taxAmountBurn = totalClaimed * (CLAIM_PIZZA_BURN_PERCENTAGE - burnSkillModifier) / 100;

        totalClaimed = totalClaimed - taxAmountFreezer - taxAmountBurn;

        pizza.mint(_msgSender(), totalClaimed);
        pizza.mint(freezerAddress, taxAmountFreezer);
    }

    function claimPizza() public nonReentrant whenNotPaused {
        address owner = _msgSender();
        _claimPizza(owner);
    }

    function unstakeChefsAndUpgrades(uint256[] calldata _chefIds, uint256[] calldata _upgradeIds) public nonReentrant whenNotPaused {
        address owner = _msgSender();
        // Check 1:1 correspondency between chef and upgrade
        require(ownedChefStakesBalance[owner] - _chefIds.length >= ownedUpgradeStakesBalance[owner] - _upgradeIds.length, "Needs at least chef for each tool");

        _claimPizza(owner);
        
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //unstake upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(stakedUpgrades[upgradeId].owner == owner, "You don't own this tool");
            require(stakedUpgrades[upgradeId].staked, "Tool needs to be staked");

            totalPPM[owner] -= upgrade.getYield(upgradeId);
            upgrade.transferFrom(address(this), owner, upgradeId);

            _removeUpgrade(upgradeId);
        }

        for (uint256 i = 0; i < _chefIds.length; i++) { //unstake chefs
            uint256 chefId = _chefIds[i];

            require(stakedChefs[chefId].owner == owner, "You don't own this token");
            require(stakedChefs[chefId].staked, "Chef needs to be staked");

            if(chef.getType(chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfChefs[owner][1]--; 
            } else {
                numberOfChefs[owner][0]--; 
            }

            totalPPM[owner] -= chef.getYield(chefId);

            _moveChefToCooldown(chefId);
        }

        _updateState(owner);
    }

    // Stake

     /**
     * This function updates stake chefs and upgrades
     * The upgrades are paired with the chef the upgrade will be applied
     */
    function stakeMany(uint256[] calldata _chefIds, uint256[] calldata _upgradeIds) public nonReentrant whenNotPaused {
        require(gameStarted(), "The game has not started");

        address owner = _msgSender();

        uint256 maxNumberChefs = getMaxNumberChefs(owner);
        uint256 chefsAfterStaking = _chefIds.length + numberOfChefs[owner][0] + numberOfChefs[owner][1];
        require(maxNumberChefs >= chefsAfterStaking, "You can't stake that many chefs");

        // Check 1:1 correspondency between chef and upgrade
        require(ownedChefStakesBalance[owner] + _chefIds.length >= ownedUpgradeStakesBalance[owner] + _upgradeIds.length, "Needs at least chef for each tool");

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
        uint256 maxLevelUpgrade = getMaxLevelUpgrade(owner);
        for (uint256 i = 0; i < _upgradeIds.length; i++) { //stakes upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(upgrade.ownerOf(upgradeId) == owner, "You don't own this tool");
            require(!stakedUpgrades[upgradeId].staked, "Tool is already staked");
            require(upgrade.getLevel(upgradeId) <= maxLevelUpgrade, "You can't equip that tool");

            upgrade.transferFrom(owner, address(this), upgradeId);
            totalPPM[owner] += upgrade.getYield(upgradeId);

             _addUpgradeToPizzeria(upgradeId, owner);
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

    function _addUpgradeToPizzeria(uint256 _tokenId, address _owner) internal {
        stakedUpgrades[_tokenId] = StakedUpgrade({
            owner: _owner,
            tokenId: _tokenId,
            staked: true
        });
        _addUpgradeToOwnerEnumeration(_owner, _tokenId);
    }


    function _addStakeToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = ownedChefStakesBalance[_owner];
        ownedChefStakes[_owner][length] = _tokenId;
        ownedChefStakesIndex[_tokenId] = length;
        ownedChefStakesBalance[_owner]++;
    }

    function _addUpgradeToOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 length = ownedUpgradeStakesBalance[_owner];
        ownedUpgradeStakes[_owner][length] = _tokenId;
        ownedUpgradeStakesIndex[_tokenId] = length;
        ownedUpgradeStakesBalance[_owner]++;
    }

    function _moveChefToCooldown(uint256 _chefId) internal {
        address owner = stakedChefs[_chefId].owner;

        uint256 endTimestamp = block.timestamp + getRestingTime(_chefId, false);
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

    // Cooldown
    function _removeUpgrade(uint256 _upgradeId) internal {
        address owner = stakedUpgrades[_upgradeId].owner;

        delete stakedUpgrades[_upgradeId];

        _removeUpgradeFromOwnerEnumeration(owner, _upgradeId);
    }

    function withdrawChefs(uint256[] calldata _chefIds) public nonReentrant whenNotPaused {
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

    function reStakeRestedChefs(uint256[] calldata _chefIds) public nonReentrant whenNotPaused {
        address owner = _msgSender();

        uint256 maxNumberChefs = getMaxNumberChefs(owner);
        uint256 chefsAfterStaking = _chefIds.length + numberOfChefs[owner][0] + numberOfChefs[owner][1];
        require(maxNumberChefs >= chefsAfterStaking, "You can't stake that many chefs");

        for (uint256 i = 0; i < _chefIds.length; i++) { //stakes chef
            uint256 _chefId = _chefIds[i];

            RestingChef memory resting = restingChefs[_chefId];

            require(resting.present, "Chef is not resting");
            require(resting.owner == owner, "You don't own this chef");
            require(block.timestamp >= resting.endTimestamp, "Chef is still resting");

            _removeChefFromCooldown(_chefId);

            _addChefToPizzeria(_chefId, owner);

            if(chef.getType(_chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfChefs[owner][1]++; 
            } else {
                numberOfChefs[owner][0]++; 
            }

            totalPPM[owner] += chef.getYield(_chefId);
        }
        _updateState(owner);
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

    function _removeUpgradeFromOwnerEnumeration(address _owner, uint256 _tokenId) internal {
        uint256 lastTokenIndex = ownedUpgradeStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedUpgradeStakesIndex[_tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedUpgradeStakes[_owner][lastTokenIndex];

            ownedUpgradeStakes[_owner][tokenIndex] = lastTokenId;
            ownedUpgradeStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedUpgradeStakesIndex[_tokenId];
        delete ownedUpgradeStakes[_owner][lastTokenIndex];
        ownedUpgradeStakesBalance[_owner]--;
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
            uint256 upgradeId = _getUpgradeStakedForChef(_owner, chefId);
            uint256 chefPPM = chef.getYield(chefId);
            uint256 upgradePPM;
            if(upgradeId > 0){
                upgradePPM = upgrade.getYield(upgradeId);
            }

            outputs[i] = StakedChefInfo({
                chefId: chefId,
                upgradeId: upgradeId,
                chefPPM: chefPPM,
                upgradePPM: upgradePPM, 
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


    // PIZZERIA MIGRATION
    Pizzeria public oldPizzeria;
    mapping(address => bool) public updateOnce; // owner => has updated

    function checkIfNeedUpdate(address _owner) public view returns (bool) {
        if(updateOnce[_owner]){
            return false; // does not need update if already updated
        }

        if(oldPizzeria.sodaDeposited(_owner) > 0){
            return true; // if the player deposited any soda it means he interacted with the Pizzeria improvements
        }

        return false;

    }

    function setOldPizzeria(address _oldPizzeria) external onlyOwner {
        oldPizzeria = Pizzeria(_oldPizzeria);
    }

    function updateDataFromOldPizzeria(address _owner) external {
        require (checkIfNeedUpdate(_owner), "Owner dont need to update");
        updateOnce[_owner] = true;

        sodaDeposited[_owner] = oldPizzeria.sodaDeposited(_owner);

        skillPoints[_owner] = oldPizzeria.skillPoints(_owner);

        uint256 burnSkillId = oldPizzeria.skillsLearned(_owner, 0);
        uint256 fatigueSkillId = oldPizzeria.skillsLearned(_owner, 1);
        uint256 freezerSkillId = oldPizzeria.skillsLearned(_owner, 2);
        uint256 masterchefSkillId = oldPizzeria.skillsLearned(_owner, 3);
        uint256 upgradeSkillId = oldPizzeria.skillsLearned(_owner, 4);
        uint256 chefSkillId = oldPizzeria.skillsLearned(_owner, 5);
        
        skillsLearned[_owner] = [burnSkillId, fatigueSkillId, freezerSkillId, masterchefSkillId, upgradeSkillId, chefSkillId];
    }

    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

}