//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/utils/Context.sol";

import "./Soda.sol";

contract PizzeriaProgression is Context{

    // Constants
    uint256[20] public SODA_LEVELS = [0, 100 * 1e18, 250 * 1e18, 450 * 1e18, 700 * 1e18, 1000 * 1e18, 1350 * 1e18, 1750 * 1e18, 2200 * 1e18, 2700 * 1e18, 3250 * 1e18, 3850 * 1e18, 4500 * 1e18, 5200 * 1e18, 5950 * 1e18, 6750 * 1e18, 7600 * 1e18, 8500 * 1e18, 9450 * 1e18, 10450 * 1e18];
    uint256 public MAX_SODA_AMOUNT = SODA_LEVELS[SODA_LEVELS.length - 1];
    uint256 public constant BURN_ID = 0;
    uint256 public constant FATIGUE_ID = 1;
    uint256 public constant FREEZER_ID = 2;
    uint256 public constant MASTERCHEF_ID = 3;
    uint256 public constant UPGRADES_ID = 4;
    uint256 public constant CHEFS_ID = 5;
    uint256[6] public MAX_SKILL_LEVEL = [3, 3, 2, 2, 5, 5];

    Soda public soda;

    mapping(address => uint256) public sodaDeposited; // address => total amount of soda deposited
    mapping(address => uint256) public skillPoints; // address => skill points available
    mapping(address => uint256[6]) public skillsLearned; // address => skill learned.

    constructor(Soda _soda) {
        soda = _soda;
    }

    // EVENTS

    event receivedSkillPoints(address owner, uint256 skillPoints);
    event skillLearned(address owner, uint256 skillGroup, uint256 skillLevel);

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
    function _getFatigueSkillModifier(address _owner) internal view returns (uint256) {
        uint256 fatigueSkill = skillsLearned[_owner][FATIGUE_ID];

        if(fatigueSkill == 3){
            return 90;
        } else if (fatigueSkill == 2){
            return 95;
        } else if (fatigueSkill == 1){
            return 98;
        } else {
            return 100;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the claim burn
    */
    function _getBurnSkillModifier(address _owner) internal view returns (uint256) {
        uint256 burnSkill = skillsLearned[_owner][BURN_ID];

        if(burnSkill == 3){
            return 5;
        } else if (burnSkill == 2){
            return 2;
        } else if (burnSkill == 1){
            return 1;
        } else {
            return 0;
        }
    }

    /**
    * Returns a value representing the % that will be reduced from the freezer share of the claim
    */
    function _getFreezerSkillModifier(address _owner) internal view returns (uint256) {
        uint256 freezerSkill = skillsLearned[_owner][FREEZER_ID];

        if(freezerSkill == 2){
            return 3;
        } else if (freezerSkill == 1){
            return 1;
        } else {
            return 0;
        }
    }

    /**
    * Returns the multiplier for $PIZZA production based on the number of masterchefs and the skill points spent
    */
    function _getMasterChefSkillModifier(address _owner, uint256 _masterChefNumber) internal view returns (uint256) {
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
    function _getMaxLevelUpgrade(address _owner) internal view returns (uint256) {
        uint256 upgradesSkill = skillsLearned[_owner][UPGRADES_ID];

        if(upgradesSkill == 0){
            return 2;
        } else if (upgradesSkill == 1){
            return 5;
        } else if (upgradesSkill == 2){
            return 7;
        } else if (upgradesSkill == 3){
            return 9;
        } else if (upgradesSkill == 4){
            return 12;
        } else {
            return 100;
        }
    }

    /**
    * Returns the max number of chefs that can be staked based on the skill points spent
    */
    function _getMaxNumberChefs(address _owner) internal view returns (uint256) {
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
            return 1000;
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

        return totalSoda - SODA_LEVELS[level-1];
    }

    /**
    * Returns the amount of soda required to level up
    */
    function getSodaToNextLevel(address _owner) public view returns (uint256) {
        uint256 level = _getLevel(_owner);
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
        uint256 freezer,
        uint256 fatigue,
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
    function depositSoda(uint256 _amount) external {
        require (_getLevel(_msgSender()) < SODA_LEVELS.length, "already at max level");
        require (soda.balanceOf(_msgSender()) >= _amount, "not enough SODA");

        if(_amount + sodaDeposited[_msgSender()] > MAX_SODA_AMOUNT){
            _amount = MAX_SODA_AMOUNT - sodaDeposited[_msgSender()];
        }

        uint256 levelBefore = _getLevel(_msgSender());
        sodaDeposited[_msgSender()] += _amount;
        uint256 levelAfter = _getLevel(_msgSender());
        skillPoints[_msgSender()] += levelAfter - levelBefore;

        emit receivedSkillPoints(_msgSender(), levelAfter - levelBefore);

        soda.burn(_msgSender(), _amount);
    }

    /**
    *  Spend skill point based on the skill group and skill level. Can only spend 1 point at a time.
    */
    function spendSkillPoints(uint256 _skillGroup, uint256 _skillLevel) external {
        require(skillPoints[_msgSender()] > 0, "Not enough skill points");
        require (_skillGroup <= 5, "Invalid Skill Group");
        require(_skillLevel >= 1 && _skillLevel <= MAX_SKILL_LEVEL[_skillGroup], "Invalid Skill Level");
        
        uint256 currentSkillLevel = skillsLearned[_msgSender()][_skillGroup];
        require(_skillLevel == currentSkillLevel + 1, "Invalid Skill Level"); //can only level up 1 point at a time

        skillsLearned[_msgSender()][_skillGroup] = _skillLevel;
        skillPoints[_msgSender()]--;

        emit skillLearned(_msgSender(), _skillGroup, _skillLevel);
    }

}
