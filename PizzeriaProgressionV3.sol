//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./Soda.sol";

contract PizzeriaProgressionV3 is Context, Ownable, Pausable {

    // Constants
    uint256[20] public SODA_LEVELS = [0, 50 * 1e18, 110 * 1e18, 185 * 1e18, 280 * 1e18, 400 * 1e18, 550 * 1e18, 735 * 1e18, 960 * 1e18, 1230 * 1e18, 1550 * 1e18, 1925 * 1e18, 2360 * 1e18, 2860 * 1e18, 3430 * 1e18, 4075 * 1e18, 4800 * 1e18, 5610 * 1e18, 6510 * 1e18, 7510 * 1e18];
    uint256 public MAX_SODA_AMOUNT = SODA_LEVELS[SODA_LEVELS.length - 1];
    uint256 public constant BURN_ID = 0;
    uint256 public constant FATIGUE_ID = 1;
    uint256 public constant FREEZER_ID = 2;
    uint256 public constant MASTERCHEF_ID = 3;
    uint256 public constant UPGRADES_ID = 4;
    uint256 public constant CHEFS_ID = 5;
    uint256[6] public MAX_SKILL_LEVEL = [3, 3, 2, 2, 5, 5];

    uint256 public baseCostRespect = 25 * 1e18;


    Soda public soda;

    uint256 public levelTime;

    mapping(address => uint256) public sodaDeposited; // address => total amount of soda deposited
    mapping(address => uint256) public skillPoints; // address => skill points available
    mapping(address => uint256[6]) public skillsLearned; // address => skill learned.

    constructor(Soda _soda) {
        soda = _soda;
    }

    // EVENTS

    event receivedSkillPoints(address owner, uint256 skillPoints);
    event skillLearned(address owner, uint256 skillGroup, uint256 skillLevel);
    event respec(address owner, uint256 level);

    // Views

    /**
    * Returns the level based on the total soda deposited
    */
    function _getLevel(address _owner) internal view returns (uint256) {
        uint256 totalSoda = sodaDeposited[_owner];

        for (uint256 i = 0; i < SODA_LEVELS.length - 1; i++) {
            if (totalSoda < SODA_LEVELS[i+1]) {
                    return i+1;
            }
        }
        return SODA_LEVELS.length;
    }

    /**
    * Returns a value representing the % of fatigue after reducing
    */
    function getFatigueSkillModifier(address _owner) public view returns (uint256) {
        uint256 fatigueSkill = skillsLearned[_owner][FATIGUE_ID];

        if(fatigueSkill == 3){
            return 80;
        } else if (fatigueSkill == 2){
            return 85;
        } else if (fatigueSkill == 1){
            return 92;
        } else {
            return 100;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the claim burn
    */
    function getBurnSkillModifier(address _owner) public view returns (uint256) {
        uint256 burnSkill = skillsLearned[_owner][BURN_ID];

        if(burnSkill == 3){
            return 8;
        } else if (burnSkill == 2){
            return 6;
        } else if (burnSkill == 1){
            return 3;
        } else {
            return 0;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the freezer share of the claim
    */
    function getFreezerSkillModifier(address _owner) public view returns (uint256) {
        uint256 freezerSkill = skillsLearned[_owner][FREEZER_ID];

        if(freezerSkill == 2){
            return 9;
        } else if (freezerSkill == 1){
            return 4;
        } else {
            return 0;
        }
    }

    /**
    * Returns the multiplier for $PIZZA production based on the number of masterchefs and the skill points spent
    */
    function getMasterChefSkillModifier(address _owner, uint256 _masterChefNumber) public view returns (uint256) {
        uint256 masterChefSkill = skillsLearned[_owner][MASTERCHEF_ID];

        if(masterChefSkill == 2 && _masterChefNumber >= 5){
            return 110;
        } else if (masterChefSkill >= 1 && _masterChefNumber >= 2){
            return 103;
        } else {
            return 100;
        }
    }

    /**
    * Returns the max level upgrade that can be staked based on the skill points spent
    */
    function getMaxLevelUpgrade(address _owner) public view returns (uint256) {
        uint256 upgradesSkill = skillsLearned[_owner][UPGRADES_ID];

        if(upgradesSkill == 0){
            return 1; //level id starts at 0, so here are first and second tiers
        } else if (upgradesSkill == 1){
            return 4;
        } else if (upgradesSkill == 2){
            return 6;
        } else if (upgradesSkill == 3){
            return 8;
        } else if (upgradesSkill == 4){
            return 11;
        } else {
            return 100;
        }
    }

    /**
    * Returns the max number of chefs that can be staked based on the skill points spent
    */
    function getMaxNumberChefs(address _owner) public view returns (uint256) {
        uint256 chefsSkill = skillsLearned[_owner][CHEFS_ID];

        if(chefsSkill == 0){
            return 10;
        } else if (chefsSkill == 1){
            return 15;
        } else if (chefsSkill == 2){
            return 20;
        } else if (chefsSkill == 3){
            return 30;
        } else if (chefsSkill == 4){
            return 50;
        } else {
            return 20000;
        }
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
        if(level == SODA_LEVELS.length){
            return 0;
        }

        return totalSoda - SODA_LEVELS[level-1];
    }

    /**
    * Returns the amount of soda required to level up
    */
    function getSodaToNextLevel(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
        if(level == SODA_LEVELS.length){
            return 0;
        }
        return SODA_LEVELS[level] - SODA_LEVELS[level-1];
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
        uint256 chefs       
    ) {
        uint256[6] memory skills = skillsLearned[_owner];

        burn = skills[BURN_ID];
        fatigue = skills[FATIGUE_ID]; 
        freezer = skills[FREEZER_ID]; 
        masterchef = skills[MASTERCHEF_ID]; 
        upgrades = skills[UPGRADES_ID];
        chefs = skills[CHEFS_ID]; 
    }

    // External

    /**
    * Burns deposited $SODA and add skill point if level up.
    */
    function depositSoda(uint256 _amount) external whenNotPaused {
        require(levelStarted(), "You can't level yet");
        require (_getLevel(_msgSender()) < SODA_LEVELS.length, "already at max level");
        require (soda.balanceOf(_msgSender()) >= _amount, "not enough SODA");

        if(_amount + sodaDeposited[_msgSender()] > MAX_SODA_AMOUNT){
            _amount = MAX_SODA_AMOUNT - sodaDeposited[_msgSender()];
        }

        uint256 levelBefore = _getLevel(_msgSender());
        sodaDeposited[_msgSender()] += _amount;
        uint256 levelAfter = _getLevel(_msgSender());
        skillPoints[_msgSender()] += levelAfter - levelBefore;

        if(levelAfter == SODA_LEVELS.length){
            skillPoints[_msgSender()] += 1;
        }

        emit receivedSkillPoints(_msgSender(), levelAfter - levelBefore);

        soda.burn(_msgSender(), _amount);
    }

    /**
    *  Spend skill point based on the skill group and skill level. Can only spend 1 point at a time.
    */
    function spendSkillPoints(uint256 _skillGroup, uint256 _skillLevel) external whenNotPaused {
        require(skillPoints[_msgSender()] > 0, "Not enough skill points");
        require (_skillGroup <= 5, "Invalid Skill Group");
        require(_skillLevel >= 1 && _skillLevel <= MAX_SKILL_LEVEL[_skillGroup], "Invalid Skill Level");
        
        uint256 currentSkillLevel = skillsLearned[_msgSender()][_skillGroup];
        require(_skillLevel == currentSkillLevel + 1, "Invalid Skill Level jump"); //can only level up 1 point at a time

        skillsLearned[_msgSender()][_skillGroup] = _skillLevel;
        skillPoints[_msgSender()]--;

        emit skillLearned(_msgSender(), _skillGroup, _skillLevel);
    }

    /**
    *  Resets skills learned for a fee
    */
    function resetSkills() external whenNotPaused {
        uint256 level = _getLevel(_msgSender());
        uint256 costToRespec = level * baseCostRespect;
        require (level > 1, "you are still at level 1");
        require (soda.balanceOf(_msgSender()) >= costToRespec, "not enough SODA");

        skillsLearned[_msgSender()][BURN_ID] = 0;
        skillsLearned[_msgSender()][FATIGUE_ID] = 0;
        skillsLearned[_msgSender()][FREEZER_ID] = 0;
        skillsLearned[_msgSender()][MASTERCHEF_ID] = 0;
        skillsLearned[_msgSender()][UPGRADES_ID] = 0;
        skillsLearned[_msgSender()][CHEFS_ID] = 0;

        skillPoints[_msgSender()] = level - 1;

        if(level == 20){
            skillPoints[_msgSender()]++;
        }

        soda.burn(_msgSender(), costToRespec);

        emit respec(_msgSender(), level);

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

    // PizzeriaProgressionV3
    function setSoda(Soda _soda) external onlyOwner {
        soda = _soda;
    }

    function setBaseCostRespect(uint256 _baseCostRespect) external onlyOwner {
        baseCostRespect = _baseCostRespect;
    }

    function setSodaLevels(uint256 _index, uint256 _newValue) external onlyOwner {
        require (_index < SODA_LEVELS.length, "invalid index");
        SODA_LEVELS[_index] = _newValue;

        if(_index == (SODA_LEVELS.length - 1)){
            MAX_SODA_AMOUNT = SODA_LEVELS[SODA_LEVELS.length - 1];
        }
    }

    // In case we rebalance the leveling costs this fixes the skill points to correct players
    function fixSkillPoints(address _player) public {
        uint256 level = _getLevel(_player);
        uint256 currentSkillPoints = skillPoints[_player];
        uint256 totalSkillsLearned = skillsLearned[_player][BURN_ID] + skillsLearned[_player][FATIGUE_ID] + skillsLearned[_player][FREEZER_ID] + skillsLearned[_player][MASTERCHEF_ID] + skillsLearned[_player][UPGRADES_ID] + skillsLearned[_player][CHEFS_ID];

        uint256 correctSkillPoints = level - 1;
        if(level == SODA_LEVELS.length){ // last level has 2 skill points
            correctSkillPoints++;
        }
        if(correctSkillPoints > currentSkillPoints + totalSkillsLearned){
            skillPoints[_player] += correctSkillPoints - currentSkillPoints - totalSkillsLearned;
        }
    }

}
