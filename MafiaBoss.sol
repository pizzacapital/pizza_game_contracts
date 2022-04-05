//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./Pizza.sol";

contract MafiaBoss is Ownable {

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct Mafioso {
        uint256 id;
        uint256 totalHp;
        uint256 currentHp;
        uint256 penalty;
        uint256 bribeMultiplier;
        uint256 bribeAmount;
    } 

    uint256 currentMafiosoId;
    mapping(uint256 => Mafioso) public mafiosos;

    struct Player {
        address owner;
        uint256 bribes;
    }

    mapping(uint256 => mapping(uint256 => Player)) public participantPlayers; // (Mafia Boss Id, player Index) => player
    
    mapping(uint256 => mapping(address => uint256)) public playerIndex; // (Mafia Boss Id, player address) => player index

    mapping(uint256 => uint256) public numberOfPlayers; // Mafia Boss Id => total number of players



    Pizza pizza;

    // Events
    event MafiosoCreated(uint256 id, uint256 totalHp);
    event MafiosoBribed(uint256 id, uint256 bribe);
    event MafiosoGone(uint256 id);

    constructor(Pizza _pizza) {
        pizza = _pizza;
    }

    function createMafioso(uint256 _totalHp, uint256 _penalty, uint256 _bribeAmount) external onlyOwner {
        require(_penalty < 80, 'Invalid penalty');
        require(_bribeAmount > 0, 'Invalid bribe amount');
        require(!mafiaIsActive(), 'There is a Mafioso already.');
        currentMafiosoId++;
        Mafioso storage mafioso = mafiosos[currentMafiosoId];
        mafioso.id = currentMafiosoId;
        mafioso.totalHp = _totalHp;
        mafioso.currentHp = _totalHp;
        mafioso.penalty = _penalty;
        mafioso.bribeMultiplier = 1;
        mafioso.bribeAmount = _bribeAmount;
        emit MafiosoCreated(mafioso.id, mafioso.totalHp);
    }

    function updatePenalty(uint256 _newPenalty) external onlyOwner {
        require(_newPenalty < 80, 'Invalid penalty');
        Mafioso storage mafioso = mafiosos[currentMafiosoId];
        mafioso.penalty = _newPenalty;
    }

    function updateBribeAmount(uint256 _bribeAmount) external onlyOwner {
        require(_bribeAmount > 0, 'Invalid bribe amount');
        Mafioso storage mafioso = mafiosos[currentMafiosoId];
        mafioso.bribeAmount = _bribeAmount;
    }

    function updateBribeMultiplier(uint256 _newbribeMultiplier) external onlyOwner {
        require(_newbribeMultiplier > 0, 'Invalid damage multiplier');
        Mafioso storage mafioso = mafiosos[currentMafiosoId];
        mafioso.bribeMultiplier = _newbribeMultiplier;
    }

    // Needs to approve Pizza first
    function bribeMafioso(uint256 _nrBribes) public {
        address owner = msg.sender;
        Mafioso storage mafioso = mafiosos[currentMafiosoId];
        uint256 _amountPizza = _nrBribes * mafioso.bribeAmount;
        require(mafioso.currentHp > 0, 'There is no active Mafioso.');
        require(pizza.balanceOf(owner) >= _amountPizza, "not enough PIZZA");

        pizza.transferFrom(address(owner), DEAD_ADDRESS, _amountPizza);

        uint256 bribeWithMultiplier = _amountPizza * mafioso.bribeMultiplier;
        if(bribeWithMultiplier > mafioso.currentHp){
            bribeWithMultiplier = mafioso.currentHp;
        }
        mafioso.currentHp -= bribeWithMultiplier;

        if(playerIndex[currentMafiosoId][owner] == 0){
            numberOfPlayers[currentMafiosoId]++;
            playerIndex[currentMafiosoId][owner] = numberOfPlayers[currentMafiosoId];
            Player storage player = participantPlayers[currentMafiosoId][numberOfPlayers[currentMafiosoId]];
            player.owner = owner;
            player.bribes += _nrBribes * mafioso.bribeMultiplier;
        } else {
            Player storage player = participantPlayers[currentMafiosoId][playerIndex[currentMafiosoId][owner]];
            player.bribes += _nrBribes * mafioso.bribeMultiplier;
        }

        emit MafiosoBribed(currentMafiosoId, bribeWithMultiplier);
        if (mafioso.currentHp == 0) {
            emit MafiosoGone(currentMafiosoId);
        }
    }


    // Views
    function getPlayerBribe(address _player) public view returns (uint256) {
        Player memory player = participantPlayers[currentMafiosoId][playerIndex[currentMafiosoId][_player]];
        return player.bribes;
    }

    function getTotalBribes() public view returns (uint256) {
        Mafioso memory mafioso = mafiosos[currentMafiosoId];
        return mafioso.totalHp - mafioso.currentHp;
    }

    function getPlayers(uint256 mafiosoId, uint256 _offset, uint256 _maxSize) public view returns (Player[] memory) {
        if (_offset >= numberOfPlayers[mafiosoId]) {
            return new Player[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= numberOfPlayers[mafiosoId]) {
            outputSize = numberOfPlayers[mafiosoId] - _offset;
        }
        Player[] memory outputs = new Player[](outputSize);

        for (uint256 i = 1; i <= outputSize; i++) {
            outputs[i-1] = participantPlayers[mafiosoId][i];
        }

        return outputs;
    }

    function currentMafioso() public view returns (Mafioso memory) {
        Mafioso memory mafioso = mafiosos[currentMafiosoId];
        return mafioso;
    }

    function mafiaIsActive() public view returns (bool) {
        Mafioso memory mafioso = mafiosos[currentMafiosoId];
        return mafioso.currentHp > 0;
    }

    function mafiaCurrentPenalty() public view returns (uint256) {
        Mafioso memory mafioso = mafiosos[currentMafiosoId];
        if(mafioso.currentHp == 0){
            return 0;
        }
        return mafioso.penalty;
    }

}