//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Pizza is ERC20("Pizza", "PIZZA"), Ownable {
    uint256 public constant ONE_PIZZA = 1e18;
    uint256 public constant NUM_PROMOTIONAL_PIZZA = 500_000;
    uint256 public constant NUM_PIZZA_SODA_LP = 20_000_000;

    uint256 public NUM_PIZZA_AVAX_LP = 30_000_000;

    address public freezerAddress;
    address public pizzeriaAddress;
    address public chefAddress;
    address public upgradeAddress;

    bool public promotionalPizzaMinted = false;
    bool public avaxLPPizzaMinted = false;
    bool public sodaLPPizzaMinted = false;

    // ADMIN

    /**
     * pizzeria yields pizza
     */
    function setPizzeriaAddress(address _pizzeriaAddress) external onlyOwner {
        pizzeriaAddress = _pizzeriaAddress;
    }

    function setFreezerAddress(address _freezerAddress) external onlyOwner {
        freezerAddress = _freezerAddress;
    }

    function setUpgradeAddress(address _upgradeAddress) external onlyOwner {
        upgradeAddress = _upgradeAddress;
    }

    /**
     * chef consumes pizza
     * chef address can only be set once
     */
    function setChefAddress(address _chefAddress) external onlyOwner {
        require(address(chefAddress) == address(0), "chef address already set");
        chefAddress = _chefAddress;
    }

    function mintPromotionalPizza(address _to) external onlyOwner {
        require(!promotionalPizzaMinted, "promotional pizza has already been minted");
        promotionalPizzaMinted = true;
        _mint(_to, NUM_PROMOTIONAL_PIZZA * ONE_PIZZA);
    }

    function mintAvaxLPPizza() external onlyOwner {
        require(!avaxLPPizzaMinted, "avax pizza LP has already been minted");
        avaxLPPizzaMinted = true;
        _mint(owner(), NUM_PIZZA_AVAX_LP * ONE_PIZZA);
    }

    function mintSodaLPPizza() external onlyOwner {
        require(!sodaLPPizzaMinted, "soda pizza LP has already been minted");
        sodaLPPizzaMinted = true;
        _mint(owner(), NUM_PIZZA_SODA_LP * ONE_PIZZA);
    }

    function setNumPizzaAvaxLp(uint256 _numPizzaAvaxLp) external onlyOwner {
        NUM_PIZZA_AVAX_LP = _numPizzaAvaxLp;
    }

    // external

    function mint(address _to, uint256 _amount) external {
        require(pizzeriaAddress != address(0) && chefAddress != address(0) && freezerAddress != address(0) && upgradeAddress != address(0), "missing initial requirements");
        require(_msgSender() == pizzeriaAddress,"msgsender does not have permission");
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        require(chefAddress != address(0) && freezerAddress != address(0) && upgradeAddress != address(0), "missing initial requirements");
        require(
            _msgSender() == chefAddress 
            || _msgSender() == freezerAddress 
            || _msgSender() == upgradeAddress,
            "msgsender does not have permission"
        );
        _burn(_from, _amount);
    }

    function transferToFreezer(address _from, uint256 _amount) external {
        require(freezerAddress != address(0), "missing initial requirements");
        require(_msgSender() == freezerAddress, "only the freezer contract can call transferToFreezer");
        _transfer(_from, freezerAddress, _amount);
    }

    function transferForUpgradesFees(address _from, uint256 _amount) external {
        require(upgradeAddress != address(0), "missing initial requirements");
        require(_msgSender() == upgradeAddress, "only the upgrade contract can call transferForUpgradesFees");
        _transfer(_from, upgradeAddress, _amount);
    }
}