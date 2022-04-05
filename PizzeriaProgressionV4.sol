//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Soda.sol";

interface IPizzeriaV3 {
    function skillPoints(address owner) external view returns (uint256);
    function skillsLearned(address owner, uint256 index) external view returns (uint256);
    function sodaDeposited(address owner) external view returns (uint256);
}

contract PizzeriaProgressionV4 is Ownable {

    // Constants
    uint256 public constant BURN_ID = 0;
    uint256 public constant FATIGUE_ID = 1;
    uint256 public constant FREEZER_ID = 2;
    uint256 public constant MASTERCHEF_ID = 3;
    uint256 public constant UPGRADES_ID = 4;
    uint256 public constant CHEFS_ID = 5;
    uint256 public constant STORAGE_ID = 6;
    uint256 public constant MAFIA_ID = 7;

    uint256[30] public sodaLevels = [0, 20 * 1e18, 48 * 1e18, 83 * 1e18, 125 * 1e18, 175 * 1e18, 235 * 1e18, 310 * 1e18, 400 * 1e18, 
        510 * 1e18, 641 * 1e18, 805 * 1e18, 1001 * 1e18, 1213 * 1e18, 1497 * 1e18, 1851 * 1e18, 2276 * 1e18, 2772 * 1e18, 3322 * 1e18, 3932 * 1e18,
        4694 * 1e18, 5608 * 1e18, 6658 * 1e18, 7877 * 1e18, 9401 * 1e18, 11229 * 1e18, 13363 * 1e18, 15801 * 1e18, 18545 * 1e18, 21593 * 1e18];

    uint256 public maxSodaAmount = sodaLevels[sodaLevels.length - 1];
    uint256 public baseCostRespect = 25 * 1e18;

    uint256[4] public burnSkillValue = [0,3,6,8];
    uint256[6] public fatigueSkillValue = [100,92,85,80,70,50];
    uint256[3] public freezerSkillValue = [0,4,9];
    uint256[3] public masterChefSkillValue = [100,103,110];
    uint256[6] public upgradesSkillValue = [1,4,6,8,11,100];
    uint256[6] public chefsSkillValue = [10,15,20,30,50,20000];
    uint256[6] public pizzaStorageSkillValue = [6000 * 1e18, 15000 * 1e18, 50000 * 1e18, 100000 * 1e18, 300000 * 1e18, 500000 * 1e18];
    uint256[4] public mafiaModSkillValue = [0,3,6,10];

    uint256[8] public MAX_SKILL_LEVEL = [
        burnSkillValue.length - 1,
        fatigueSkillValue.length - 1,
        freezerSkillValue.length - 1,
        masterChefSkillValue.length - 1,
        upgradesSkillValue.length - 1,
        chefsSkillValue.length - 1,
        pizzaStorageSkillValue.length - 1,
        mafiaModSkillValue.length - 1
    ];

    Soda public soda;

    uint256 public levelTime;

    mapping(address => uint256) public sodaDeposited; // address => total amount of soda deposited
    mapping(address => uint256) public skillPoints; // address => skill points available
    mapping(address => uint256[8]) public skillsLearned; // address => skill learned.

    constructor(Soda _soda) {
        soda = _soda;
    }

    // EVENTS

    event receivedSkillPoints(address owner, uint256 skillPoints);
    event skillLearned(address owner, uint256 skillGroup, uint256 skillLevel);
    event respec(address owner, uint256 level);

    // Setters
    function setburnSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        burnSkillValue[_index] = _value;
    }
    function setfatigueSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        fatigueSkillValue[_index] = _value;
    }
    function setfreezerSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        freezerSkillValue[_index] = _value;
    }
    function setmasterChefSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        masterChefSkillValue[_index] = _value;
    }
    function setupgradesSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        upgradesSkillValue[_index] = _value;
    }
    function setchefsSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        chefsSkillValue[_index] = _value;
    }
    function setpizzaStorageSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        pizzaStorageSkillValue[_index] = _value;
    }
    function setmafiaModSkillValue(uint256 _index, uint256 _value) external onlyOwner {
        mafiaModSkillValue[_index] = _value;
    }
    
    function setSoda(Soda _soda) external onlyOwner {
        soda = _soda;
    }

    function setBaseCostRespect(uint256 _baseCostRespect) external onlyOwner {
        baseCostRespect = _baseCostRespect;
    }

    function setSodaLevels(uint256 _index, uint256 _newValue) external onlyOwner {
        require (_index < sodaLevels.length, "invalid index");
        sodaLevels[_index] = _newValue;

        if(_index == (sodaLevels.length - 1)){
            maxSodaAmount = sodaLevels[sodaLevels.length - 1];
        }
    }

    // Views

    /**
    * Returns the level based on the total soda deposited
    */
    function _getLevel(address _owner) internal view returns (uint256) {
        uint256 totalSoda = sodaDeposited[_owner];
        uint256 maxId = sodaLevels.length - 1;

        for (uint256 i = 0; i < maxId; i++) {
            if (totalSoda < sodaLevels[i+1]) {
                    return i+1;
            }
        }
        return sodaLevels.length;
    }

    /**
    * Returns a value representing the % of fatigue after reducing
    */
    function getFatigueSkillModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkill = skillsLearned[_owner][FATIGUE_ID];
        return fatigueSkillValue[fatigueSkill];
    }

    /**
    * Returns a value representing the % that will be reduced from the claim burn
    */
    function getBurnSkillModifier(address _owner) public view returns (uint256) {
        uint256 burnSkill = skillsLearned[_owner][BURN_ID];
        return burnSkillValue[burnSkill];
    }

    /**
    * Returns a value representing the % that will be reduced from the freezer share of the claim
    */
    function getFreezerSkillModifier(address _owner) public view returns (uint256) {
        uint256 freezerSkill = skillsLearned[_owner][FREEZER_ID];
        return freezerSkillValue[freezerSkill];
    }

    /**
    * Returns the multiplier for $PIZZA production based on the number of masterchefs and the skill points spent
    */
    function getMasterChefSkillModifier(address _owner, uint256 _masterChefNumber) public view returns (uint256) {
        uint256 masterChefSkill = skillsLearned[_owner][MASTERCHEF_ID];

        if(masterChefSkill == 2 && _masterChefNumber >= 5){
            return masterChefSkillValue[2];
        } else if (masterChefSkill >= 1 && _masterChefNumber >= 2){
            return masterChefSkillValue[1];
        } else {
            return masterChefSkillValue[0];
        }
    }

    /**
    * Returns the max level upgrade that can be staked based on the skill points spent
    */
    function getMaxLevelUpgrade(address _owner) public view returns (uint256) {
        uint256 upgradesSkill = skillsLearned[_owner][UPGRADES_ID];
        return upgradesSkillValue[upgradesSkill];
    }

    /**
    * Returns the max number of chefs that can be staked based on the skill points spent
    */
    function getMaxNumberChefs(address _owner) public view returns (uint256) {
        uint256 chefsSkill = skillsLearned[_owner][CHEFS_ID];
        return chefsSkillValue[chefsSkill];
    }

    /**
    * Returns the modifier for mafia mechanic
    */
    function getMafiaModifier(address _owner) public view returns (uint256) {
        uint256 mafiaModSkill = skillsLearned[_owner][MAFIA_ID];
        return mafiaModSkillValue[mafiaModSkill];
    }

    /**
    * Returns the max storage for pizza in the pizzeria
    */
    function getPizzaStorage(address _owner) public view returns (uint256) {
        uint256 pizzaStorageSkill = skillsLearned[_owner][STORAGE_ID];
        return pizzaStorageSkillValue[pizzaStorageSkill];
    }

    // Public views

    /**
    * Returns the Pizzeria level
    */
    function getLevel(address _owner) public view returns (uint256) {
        return _getLevel(_owner);
    }

    /**
    * Returns the $SODA deposited in the current level
    */
    function getSodaDeposited(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
        uint256 totalSoda = sodaDeposited[_owner];
        if(level == sodaLevels.length){
            return 0;
        }

        return totalSoda - sodaLevels[level-1];
    }

    /**
    * Returns the amount of soda required to level up
    */
    function getSodaToNextLevel(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
        if(level == sodaLevels.length){
            return 0;
        }
        return sodaLevels[level] - sodaLevels[level-1];
    }

    /**
    * Returns the amount of skills points available to be spent
    */
    function getSkillPoints(address _owner) public view returns (uint256) {
        return skillPoints[_owner];
    }

    /**
    * Returns the current skills levels for each skill group
    */
    function getSkillsLearned(address _owner) public view returns (
        uint256 burn,
        uint256 fatigue,
        uint256 freezer,
        uint256 masterchef,
        uint256 upgrades,
        uint256 chefs,     
        uint256 pizzaStorage,     
        uint256 mafiaMod     
    ) {
        uint256[8] memory skills = skillsLearned[_owner];

        burn = skills[BURN_ID];
        fatigue = skills[FATIGUE_ID]; 
        freezer = skills[FREEZER_ID]; 
        masterchef = skills[MASTERCHEF_ID]; 
        upgrades = skills[UPGRADES_ID];
        chefs = skills[CHEFS_ID]; 
        pizzaStorage = skills[STORAGE_ID]; 
        mafiaMod = skills[MAFIA_ID]; 
    }

    // External

    /**
    * Burns deposited $SODA and add skill point if level up.
    */
    function depositSoda(uint256 _amount) external {
        address sender = msg.sender;
        require(levelStarted(), "You can't level yet");
        require (_getLevel(sender) < sodaLevels.length, "already at max level");
        require (soda.balanceOf(sender) >= _amount, "not enough SODA");

        if(_amount + sodaDeposited[sender] > maxSodaAmount){
            _amount = maxSodaAmount - sodaDeposited[sender];
        }

        soda.burn(sender, _amount);

        uint256 levelBefore = _getLevel(sender);
        sodaDeposited[sender] += _amount;
        uint256 levelAfter = _getLevel(sender);
        skillPoints[sender] += levelAfter - levelBefore;

        if(levelAfter == sodaLevels.length){
            skillPoints[sender] += 1;
        }

        emit receivedSkillPoints(sender, levelAfter - levelBefore);
    }

    /**
    *  Spend skill point based on the skill group and skill level. Can only spend 1 point at a time.
    */
    function spendSkillPoints(uint256 _skillGroup, uint256 _skillLevel) external {
        address sender = msg.sender;

        require(skillPoints[sender] > 0, "Not enough skill points");
        require (_skillGroup <= MAX_SKILL_LEVEL.length - 1, "Invalid Skill Group");
        require(_skillLevel >= 1 && _skillLevel <= MAX_SKILL_LEVEL[_skillGroup], "Invalid Skill Level");
        
        uint256 currentSkillLevel = skillsLearned[sender][_skillGroup];
        require(_skillLevel == currentSkillLevel + 1, "Invalid Skill Level jump"); //can only level up 1 point at a time

        skillsLearned[sender][_skillGroup] = _skillLevel;
        skillPoints[sender]--;

        emit skillLearned(sender, _skillGroup, _skillLevel);
    }

    /**
    *  Resets skills learned for a fee
    */
    function resetSkills() external {
        address sender = msg.sender;
        uint256 level = _getLevel(sender);
        uint256 costToRespec = level * baseCostRespect;
        require (level > 1, "you are still at level 1");
        require (soda.balanceOf(sender) >= costToRespec, "not enough SODA");

        soda.burn(sender, costToRespec);

        skillsLearned[sender][BURN_ID] = 0;
        skillsLearned[sender][FATIGUE_ID] = 0;
        skillsLearned[sender][FREEZER_ID] = 0;
        skillsLearned[sender][MASTERCHEF_ID] = 0;
        skillsLearned[sender][UPGRADES_ID] = 0;
        skillsLearned[sender][CHEFS_ID] = 0;
        skillsLearned[sender][STORAGE_ID] = 0;
        skillsLearned[sender][MAFIA_ID] = 0;

        skillPoints[sender] = level - 1;

        if(level == sodaLevels.length){
            skillPoints[sender] += 1;
        }

        emit respec(sender, level);

    }

    // Admin

    function levelStarted() public view returns (bool) {
        return levelTime != 0 && block.timestamp >= levelTime;
    }

    function setLevelStartTime(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        require(!levelStarted(), "leveling already started");
        levelTime = _startTime;
    }


    // In case we rebalance the leveling costs this fixes the skill points to correct players
    function fixSkillPoints(address _player) public {
        uint256 level = _getLevel(_player);
        uint256 currentSkillPoints = skillPoints[_player];
        uint256 totalSkillsLearned = skillsLearned[_player][BURN_ID] + skillsLearned[_player][FATIGUE_ID] + skillsLearned[_player][FREEZER_ID] + skillsLearned[_player][MASTERCHEF_ID] + skillsLearned[_player][UPGRADES_ID] + skillsLearned[_player][CHEFS_ID] + skillsLearned[_player][STORAGE_ID] + skillsLearned[_player][MAFIA_ID];

        uint256 correctSkillPoints = level - 1;
        if(level == sodaLevels.length){ // last level has 2 skill points
            correctSkillPoints += 1;
        }
        if(correctSkillPoints > currentSkillPoints + totalSkillsLearned){
            skillPoints[_player] += correctSkillPoints - currentSkillPoints - totalSkillsLearned;
        }
    }

        // PIZZERIA MIGRATION
    IPizzeriaV3 public oldPizzeria;
    mapping(address => bool) public updateOnce; // owner => has updated

    function checkIfNeedUpdate(address _owner) public view returns (bool) {
        if(updateOnce[_owner]){
            return false; // does not need update if already updated
        }

        uint256 oldSodaDeposited = oldPizzeria.sodaDeposited(_owner);

        if(oldSodaDeposited > 0){
            return true; // if the player deposited any soda it means he interacted with the Pizzeria improvements
        }

        return false;

    }

    function setOldPizzeria(address _oldPizzeria) external onlyOwner {
        oldPizzeria = IPizzeriaV3(_oldPizzeria);
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
        
        skillsLearned[_owner] = [burnSkillId, fatigueSkillId, freezerSkillId, masterchefSkillId, upgradeSkillId, chefSkillId, 0, 0];

        fixSkillPoints(_owner); // Fix skill points because of rebalance
    }

}
