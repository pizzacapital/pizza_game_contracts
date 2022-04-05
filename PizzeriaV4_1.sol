//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

// Open Zeppelin libraries for controlling upgradability and access.
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./Chef.sol";
import "./Upgrade.sol";
import "./Pizza.sol";
import "./Soda.sol";

interface IPizzeriaProgressionV4_1 {
    function getFatigueSkillModifier(address owner) external view returns (uint256);
    function getBurnSkillModifier(address owner) external view returns (uint256);
    function getFreezerSkillModifier(address owner) external view returns (uint256);
    function getMasterChefSkillModifier(address owner, uint256 masterChefNumber) external view returns (uint256);
    function getMaxLevelUpgrade(address owner) external view returns (uint256);
    function getMaxNumberChefs(address owner) external view returns (uint256);
    function getMafiaModifier(address owner) external view returns (uint256);
    function getPizzaStorage(address owner) external view returns (uint256);
}

interface IMafia_1 {
    function mafiaIsActive() external view returns (bool);
    function mafiaCurrentPenalty() external view returns (uint256);
}

contract PizzeriaV4_1 is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    // Constants
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant CLAIM_PIZZA_CONTRIBUTION_PERCENTAGE = 10;
    uint256 public constant CLAIM_PIZZA_BURN_PERCENTAGE = 10;
    uint256 public constant MAX_FATIGUE = 100000000000000;

    // Staking

    mapping(uint256 => address) public stakedChefs; // tokenId => owner

    mapping(address => uint256) public fatiguePerMinute; // address => fatigue per minute in the pizzeria
    mapping(address => uint256) public pizzeriaFatigue; // address => fatigue
    mapping(address => uint256) public pizzeriaPizza; // address => pizza
    mapping(address => uint256) public totalPPM; // address => total PPM
    mapping(address => uint256) public startTimeStamp; // address => startTimeStamp

    mapping(address => uint256[2]) public numberOfStaked; // address => [number of chefs, number of master chefs]

    mapping(uint256 => address) public stakedUpgrades; // tokenId => owner

    // Enumeration
    mapping(address => mapping(uint256 => uint256)) public ownedChefStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) public ownedChefStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedChefStakesBalance; // address => stake count

    mapping(address => mapping(uint256 => uint256)) public ownedUpgradeStakes; // (address, index) => tokenid
    mapping(uint256 => uint256) public ownedUpgradeStakesIndex; // tokenId => index in its owner's stake list
    mapping(address => uint256) public ownedUpgradeStakesBalance; // address => stake count

    // Fatigue cooldowns
    mapping(uint256 => uint256) public restingChefs; // tokenId => timestamp until rested. 0 if is not resting

    // Var

    uint256 public yieldPPS; // pizza cooked per second per unit of yield

    uint256 public startTime;

    uint256 public sodaResetCost; // 0.1 Soda is the cost per PPM

    uint256 public unstakePenalty; // Everytime someone unstake they need to pay this tax from the unclaimed amount

    uint256 public fatigueTuner;

    Chef public chef;
    Upgrade public upgrade;
    Pizza public pizza;
    Soda public soda;
    address public freezerAddress;
    IPizzeriaProgressionV4_1 public pizzeriaProgression;
    IMafia_1 public mafia;
    address public mafiaAddress;

    function initialize(Chef _chef, Upgrade _upgrade, Pizza _pizza, Soda _soda, address _freezerAddress, address _pizzeriaProgression) public initializer {
        chef = _chef;
        soda = _soda;
        upgrade = _upgrade;
        pizza = _pizza;
        freezerAddress = _freezerAddress;
        pizzeriaProgression = IPizzeriaProgressionV4_1(_pizzeriaProgression);

        yieldPPS = 16666666666666667; // pizza cooked per second per unit of yield
        startTime;
        sodaResetCost = 1e17; // 0.1 Soda is the cost per PPM
        unstakePenalty = 2000 * 1e18; // Everytime someone unstake they need to pay this tax from the unclaimed amount
        fatigueTuner = 100;

      ///@dev as there is no constructor, we need to initialise the OwnableUpgradeable explicitly
       __Ownable_init();
    }
    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address) internal override onlyOwner {}


    // Setters
    function setPizza(Pizza _pizza) external onlyOwner {
        pizza = _pizza;
    }
    function setFreezerAddress(address _freezerAddress) external onlyOwner {
        freezerAddress = _freezerAddress;
    }
    function setChef(Chef _chef) external onlyOwner {
        chef = _chef;
    }
    function setUpgrade(Upgrade _upgrade) external onlyOwner {
        upgrade = _upgrade;
    }
    function setYieldPPS(uint256 _yieldPPS) external onlyOwner {
        yieldPPS = _yieldPPS;
    }
    function setSodaResetCost(uint256 _sodaResetCost) external onlyOwner {
        sodaResetCost = _sodaResetCost;
    }
    function setUnstakePenalty(uint256 _unstakePenalty) external onlyOwner {
        unstakePenalty = _unstakePenalty;
    }
    function setFatigueTuner(uint256 _fatigueTuner) external onlyOwner {
        fatigueTuner = _fatigueTuner;
    }
    
    function setSoda(Soda _soda) external onlyOwner {
        soda = _soda;
    }
    function setPizzeriaProgression(address _pizzeriaProgression) external onlyOwner {
        pizzeriaProgression = IPizzeriaProgressionV4_1(_pizzeriaProgression);
    }
    function setMafia(address _mafia) external onlyOwner {
        mafiaAddress = _mafia;
        mafia = IMafia_1(_mafia);
    }
    // Calculations

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
            return 0;
        }
        return d + c * _ppm + a * _ppm * _ppm * _ppm - b * _ppm * _ppm;
    }

    /**
     * Returns the timestamp of when the entire pizzeria will be fatigued
     */
    function timeUntilFatiguedCalculation(uint256 _startTime, uint256 _fatigue, uint256 _fatiguePerMinute) public pure returns (uint256) {
        if(_fatiguePerMinute == 0){
            return _startTime + 31536000; // 1 year in seconds, arbitrary long duration
        }
        return _startTime + 60 * ( MAX_FATIGUE - _fatigue ) / _fatiguePerMinute;
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

    /**
     * Returns chef's pizza from chefPizza mapping
     */
     function pizzaAccruedCalculation(uint256 _initialPizza, uint256 _deltaTime, uint256 _ppm, uint256 _modifier, uint256 _fatigue, uint256 _fatiguePerMinute, uint256 _yieldPPS) public pure returns (uint256) {
        if(_fatigue >= MAX_FATIGUE){
            return _initialPizza;
        }

        uint256 a = _deltaTime * _ppm * _yieldPPS * _modifier * (MAX_FATIGUE - _fatigue) / ( 100 * MAX_FATIGUE);
        uint256 b = _deltaTime * _deltaTime * _ppm * _yieldPPS * _modifier * _fatiguePerMinute / (100 * 2 * 60 * MAX_FATIGUE);
        if(a > b){
            return _initialPizza + a - b;
        }

        return _initialPizza;
    }

    // Views

    function getFatiguePerMinuteWithModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkillModifier = pizzeriaProgression.getFatigueSkillModifier(_owner);
        return fatiguePerMinute[_owner]*fatigueSkillModifier*fatigueTuner/(100*100);
    }

    function _getMasterChefNumber(address _owner) internal view returns (uint256) {
        return numberOfStaked[_owner][1];
    }

    /**
     * Returns the current chef's fatigue
     */
    function getFatigueAccrued(address _owner) public view returns (uint256) {
        uint256 fatigue = (block.timestamp - startTimeStamp[_owner]) * getFatiguePerMinuteWithModifier(_owner) / 60;
        fatigue += pizzeriaFatigue[_owner];
        if (fatigue > MAX_FATIGUE) {
            fatigue = MAX_FATIGUE;
        }
        return fatigue;
    }

    function getTimeUntilFatigued(address _owner) public view returns (uint256) {
        return timeUntilFatiguedCalculation(startTimeStamp[_owner], pizzeriaFatigue[_owner], getFatiguePerMinuteWithModifier(_owner));
    }

    function getRestingTime(uint256 _tokenId, address _owner) public view returns (uint256) {
        return restingTimeCalculation(chef.getType(_tokenId), chef.MASTER_CHEF_TYPE(), getFatigueAccrued(_owner));
    }

    function getPizzaAccrued(address _owner) public view returns (uint256) {
        // if fatigueLastUpdate = MAX_FATIGUE it means that pizzeriaPizza already has the correct value for the pizza, since it didn't produce pizza since last update
        uint256 fatigueLastUpdate = pizzeriaFatigue[_owner];
        if(fatigueLastUpdate == MAX_FATIGUE){
            return pizzeriaPizza[_owner];
        }

        uint256 timeUntilFatigued = getTimeUntilFatigued(_owner);

        uint256 endTimestamp;
        if(block.timestamp >= timeUntilFatigued){
            endTimestamp = timeUntilFatigued;
        } else {
            endTimestamp = block.timestamp;
        }

        uint256 ppm = getTotalPPM(_owner);

        uint256 masterChefSkillModifier = pizzeriaProgression.getMasterChefSkillModifier(_owner, _getMasterChefNumber(_owner));

        uint256 delta = endTimestamp - startTimeStamp[_owner];

        uint256 newPizzaAmount = pizzaAccruedCalculation(pizzeriaPizza[_owner], delta, ppm, masterChefSkillModifier, fatigueLastUpdate, getFatiguePerMinuteWithModifier(_owner), yieldPPS);

        uint256 maxPizza = pizzeriaProgression.getPizzaStorage(_owner);

        if(newPizzaAmount > maxPizza){
            return maxPizza;
        }
        return newPizzaAmount;
    }

    /**
     * Calculates the total PPM staked for a pizzeria. 
     * This will also be used in the fatiguePerMinute calculation
     */
    function getTotalPPM(address _owner) public view returns (uint256) {
        return totalPPM[_owner];
    }

    function _updatefatiguePerMinute(address _owner) internal {
        uint256 ppm = totalPPM[_owner];
        if(ppm == 0){
            delete pizzeriaFatigue[_owner];
        }
        fatiguePerMinute[_owner] = fatiguePerMinuteCalculation(ppm);
    }

    //Claim
    function _claimPizza(address _owner) internal {
        uint256 freezerSkillModifier = pizzeriaProgression.getFreezerSkillModifier(_owner);
        uint256 burnSkillModifier = pizzeriaProgression.getBurnSkillModifier(_owner);

        uint256 totalClaimed = getPizzaAccrued(_owner);

        delete pizzeriaPizza[_owner];

        pizzeriaFatigue[_owner] = getFatigueAccrued(_owner);

        startTimeStamp[_owner] = block.timestamp;

        uint256 taxAmountFreezer = totalClaimed * (CLAIM_PIZZA_CONTRIBUTION_PERCENTAGE - freezerSkillModifier) / 100;
        uint256 taxAmountBurn = totalClaimed * (CLAIM_PIZZA_BURN_PERCENTAGE - burnSkillModifier) / 100;

        uint256 taxAmountMafia = 0;
        if(mafiaAddress != address(0) && mafia.mafiaIsActive()){
            uint256 mafiaSkillModifier = pizzeriaProgression.getMafiaModifier(_owner);
            uint256 penalty = mafia.mafiaCurrentPenalty();
            if(penalty < mafiaSkillModifier){
                taxAmountMafia = 0;
            } else {
                taxAmountMafia = totalClaimed * (penalty - mafiaSkillModifier) / 100;
            }
        }

        totalClaimed = totalClaimed - taxAmountFreezer - taxAmountBurn - taxAmountMafia;

        pizza.mint(_owner, totalClaimed);
        pizza.mint(freezerAddress, taxAmountFreezer);
    }

    function claimPizza() public {
        address owner = msg.sender;
        _claimPizza(owner);
    }

    function _updateState(address _owner) internal {
        pizzeriaPizza[_owner] = getPizzaAccrued(_owner);

        pizzeriaFatigue[_owner] = getFatigueAccrued(_owner);

        startTimeStamp[_owner] = block.timestamp;
    }

    //Resets fatigue and claims
    //Will need to approve soda first
    function resetFatigue() public {
        address _owner = msg.sender;
        uint256 ppm = getTotalPPM(_owner);
        uint256 costToReset = ppm * sodaResetCost;
        require(soda.balanceOf(_owner) >= costToReset, "not enough SODA");

        soda.transferFrom(address(_owner), DEAD_ADDRESS, costToReset);

        pizzeriaPizza[_owner] = getPizzaAccrued(_owner);
        startTimeStamp[_owner] = block.timestamp;
        delete pizzeriaFatigue[_owner];
    }

    function _taxUnstake(address _owner, uint256 _taxableAmount) internal {
        uint256 totalClaimed = getPizzaAccrued(_owner);
        uint256 penaltyCost = _taxableAmount * unstakePenalty;
        require(totalClaimed >= penaltyCost, "Not enough Pizza to pay the unstake penalty.");

        pizzeriaPizza[_owner] = totalClaimed - penaltyCost;

        pizzeriaFatigue[_owner] = getFatigueAccrued(_owner);

        startTimeStamp[_owner] = block.timestamp;
    }


    function unstakeChefsAndUpgrades(uint256[] calldata _chefIds, uint256[] calldata _upgradeIds) public {
        address owner = msg.sender;
        // Check 1:1 correspondency between chef and upgrade
        require(numberOfStaked[owner][0] + numberOfStaked[owner][1] >= _chefIds.length, "Invalid number of chefs");
        require(ownedUpgradeStakesBalance[owner] >= _upgradeIds.length, "Invalid number of tools");
        require(numberOfStaked[owner][0] + numberOfStaked[owner][1] - _chefIds.length >= ownedUpgradeStakesBalance[owner] - _upgradeIds.length, "Needs at least chef for each tool");

        uint256 upgradeLength = _upgradeIds.length;
        uint256 chefLength = _chefIds.length;

        _taxUnstake(owner, upgradeLength + chefLength);
        
        for (uint256 i = 0; i < upgradeLength; i++) { //unstake upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(stakedUpgrades[upgradeId] == owner, "You don't own this tool");

            upgrade.transferFrom(address(this), owner, upgradeId);

            totalPPM[owner] -= upgrade.getYield(upgradeId);

            _removeUpgrade(upgradeId, owner);

        }

        for (uint256 i = 0; i < chefLength; i++) { //unstake chefs
            uint256 chefId = _chefIds[i];

            require(stakedChefs[chefId] == owner, "You don't own this token");
            require(restingChefs[chefId] == 0, "Chef is resting");

            if(chef.getType(chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfStaked[owner][1]--; 
            } else {
                numberOfStaked[owner][0]--;
            }

            totalPPM[owner] -= chef.getYield(chefId);

            _moveChefToCooldown(chefId, owner);
        }

        _updatefatiguePerMinute(owner);
    }

    // Stake

     /**
     * This function updates stake chefs and upgrades
     * The upgrades are paired with the chef the upgrade will be applied
     */
    function stakeMany(uint256[] calldata _chefIds, uint256[] calldata _upgradeIds) public {
        require(gameStarted(), "The game has not started");

        address owner = msg.sender;

        uint256 maxNumberChefs = pizzeriaProgression.getMaxNumberChefs(owner);
        uint256 chefsAfterStaking = _chefIds.length + numberOfStaked[owner][0] + numberOfStaked[owner][1];
        require(maxNumberChefs >= chefsAfterStaking, "You can't stake that many chefs");

        // Check 1:1 correspondency between chef and upgrade
        require(chefsAfterStaking >= ownedUpgradeStakesBalance[owner] + _upgradeIds.length, "Needs at least chef for each tool");

        _updateState(owner);

        uint256 chefLength = _chefIds.length;
        for (uint256 i = 0; i < chefLength; i++) { //stakes chef
            uint256 chefId = _chefIds[i];

            require(chef.ownerOf(chefId) == owner, "You don't own this token");
            require(chef.getType(chefId) > 0, "Chef not yet revealed");

            if(chef.getType(chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfStaked[owner][1]++;
            } else {
                numberOfStaked[owner][0]++;
            }

            totalPPM[owner] += chef.getYield(chefId);

            _addChefToPizzeria(chefId, owner);

            chef.transferFrom(owner, address(this), chefId);
        }
        uint256 maxLevelUpgrade = pizzeriaProgression.getMaxLevelUpgrade(owner);
        uint256 upgradeLength = _upgradeIds.length;
        for (uint256 i = 0; i < upgradeLength; i++) { //stakes upgrades
            uint256 upgradeId = _upgradeIds[i];

            require(upgrade.ownerOf(upgradeId) == owner, "You don't own this tool");
            require(upgrade.getLevel(upgradeId) <= maxLevelUpgrade, "You can't equip that tool");

            totalPPM[owner] += upgrade.getYield(upgradeId);

            _addUpgradeToPizzeria(upgradeId, owner);

            upgrade.transferFrom(owner, address(this), upgradeId);

        }
        _updatefatiguePerMinute(owner);
    }

    function withdrawChefs(uint256[] calldata _chefIds) public {
        address owner = msg.sender;
        uint256 chefLength = _chefIds.length;
        for (uint256 i = 0; i < chefLength; i++) {
            uint256 _chefId = _chefIds[i];

            require(restingChefs[_chefId] != 0, "Chef is not resting");
            require(stakedChefs[_chefId] == owner, "You don't own this chef");
            require(block.timestamp >= restingChefs[_chefId], "Chef is still resting");

            _removeChefFromCooldown(_chefId, owner);

            chef.transferFrom(address(this), owner, _chefId);
        }
    }

    function reStakeRestedChefs(uint256[] calldata _chefIds) public {
        address owner = msg.sender;

        uint256 maxNumberChefs = pizzeriaProgression.getMaxNumberChefs(owner);
        uint256 chefsAfterStaking = _chefIds.length + numberOfStaked[owner][0] + numberOfStaked[owner][1];
        require(maxNumberChefs >= chefsAfterStaking, "You can't stake that many chefs");

        _updateState(owner);

        uint256 chefLength = _chefIds.length;
        for (uint256 i = 0; i < chefLength; i++) { //stakes chef
            uint256 _chefId = _chefIds[i];

            require(restingChefs[_chefId] != 0, "Chef is not resting");
            require(stakedChefs[_chefId] == owner, "You don't own this chef");
            require(block.timestamp >= restingChefs[_chefId], "Chef is still resting");

            delete restingChefs[_chefId];

            if(chef.getType(_chefId) == chef.MASTER_CHEF_TYPE()){
                numberOfStaked[owner][1]++;
            } else {
                numberOfStaked[owner][0]++;
            }

            totalPPM[owner] += chef.getYield(_chefId);
        }
        _updatefatiguePerMinute(owner);
    }

    function _addChefToPizzeria(uint256 _tokenId, address _owner) internal {
        stakedChefs[_tokenId] = _owner;
        uint256 length = ownedChefStakesBalance[_owner];
        ownedChefStakes[_owner][length] = _tokenId;
        ownedChefStakesIndex[_tokenId] = length;
        ownedChefStakesBalance[_owner]++;
    }

    function _addUpgradeToPizzeria(uint256 _tokenId, address _owner) internal {
        stakedUpgrades[_tokenId] = _owner;
        uint256 length = ownedUpgradeStakesBalance[_owner];
        ownedUpgradeStakes[_owner][length] = _tokenId;
        ownedUpgradeStakesIndex[_tokenId] = length;
        ownedUpgradeStakesBalance[_owner]++;
    }

    function _moveChefToCooldown(uint256 _chefId, address _owner) internal {
        uint256 endTimestamp = block.timestamp + getRestingTime(_chefId, _owner);
        restingChefs[_chefId] = endTimestamp;
    }

    function _removeChefFromCooldown(uint256 _chefId, address _owner) internal {
        delete restingChefs[_chefId];
        delete stakedChefs[_chefId];

        uint256 lastTokenIndex = ownedChefStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedChefStakesIndex[_chefId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedChefStakes[_owner][lastTokenIndex];

            ownedChefStakes[_owner][tokenIndex] = lastTokenId;
            ownedChefStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedChefStakesIndex[_chefId];
        delete ownedChefStakes[_owner][lastTokenIndex];
        ownedChefStakesBalance[_owner]--;
    }

    function _removeUpgrade(uint256 _upgradeId, address _owner) internal {
        delete stakedUpgrades[_upgradeId];
        
        uint256 lastTokenIndex = ownedUpgradeStakesBalance[_owner] - 1;
        uint256 tokenIndex = ownedUpgradeStakesIndex[_upgradeId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedUpgradeStakes[_owner][lastTokenIndex];

            ownedUpgradeStakes[_owner][tokenIndex] = lastTokenId;
            ownedUpgradeStakesIndex[lastTokenId] = tokenIndex;
        }

        delete ownedUpgradeStakesIndex[_upgradeId];
        delete ownedUpgradeStakes[_owner][lastTokenIndex];
        ownedUpgradeStakesBalance[_owner]--;
    }

    // Admin

    function gameStarted() public view returns (bool) {
        return startTime != 0 && block.timestamp >= startTime;
    }

    function setStartTime(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        require(!gameStarted(), "game already started");
        startTime = _startTime;
    }

    // Aggregated views
    struct StakedChefInfo {
        uint256 chefId;
        uint256 chefPPM;
        bool isResting;
        uint256 endTimestamp;
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
            uint256 chefId = ownedChefStakes[_owner][_offset + i];

            outputs[i] = StakedChefInfo({
                chefId: chefId,
                chefPPM: chef.getYield(chefId),
                isResting: restingChefs[chefId] > 0,
                endTimestamp: restingChefs[chefId]
            });
        }

        return outputs;
    }

    struct StakedToolInfo {
        uint256 toolId;
        uint256 toolPPM;
    }

    function batchedToolsOfOwner(
        address _owner,
        uint256 _offset,
        uint256 _maxSize
    ) public view returns (StakedToolInfo[] memory) {
        if (_offset >= ownedUpgradeStakesBalance[_owner]) {
            return new StakedToolInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= ownedUpgradeStakesBalance[_owner]) {
            outputSize = ownedUpgradeStakesBalance[_owner] - _offset;
        }
        StakedToolInfo[] memory outputs = new StakedToolInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 toolId = ownedUpgradeStakes[_owner][_offset + i];

            outputs[i] = StakedToolInfo({
                toolId: toolId,
                toolPPM: upgrade.getYield(toolId)
            });
        }

        return outputs;
    }

}