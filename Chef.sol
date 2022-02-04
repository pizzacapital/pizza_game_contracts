//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import "./Pizza.sol";

contract Chef is ERC721Enumerable, Ownable, Pausable {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    struct ChefInfo {
        uint256 tokenId;
        uint256 chefType;
    }

    // CONSTANTS

    uint256 public constant CHEF_PRICE_WHITELIST = 1 ether;
    uint256 public constant CHEF_PRICE_AVAX = 1.5 ether;

    uint256 public constant WHITELIST_CHEFS = 1000; 
    uint256 public constant CHEFS_PER_PIZZA_MINT_LEVEL = 5000;

    uint256 public constant MAXIMUM_MINTS_PER_WHITELIST_ADDRESS = 4;

    uint256 public constant NUM_GEN0_CHEFS = 10_000;
    uint256 public constant NUM_GEN1_CHEFS = 10_000;

    uint256 public constant CHEF_TYPE = 1;
    uint256 public constant MASTER_CHEF_TYPE = 2;

    uint256 public constant CHEF_YIELD = 1;
    uint256 public constant MASTER_CHEF_YIELD = 3;

    uint256 public constant PROMOTIONAL_CHEFS = 50;

    // VAR

    // external contracts
    Pizza public pizza;
    address public pizzeriaAddress;
    address public chefTypeOracleAddress;

    // metadata URI
    string public BASE_URI;

    // chef type definitions (normal or master?)
    mapping(uint256 => uint256) public tokenTypes; // maps tokenId to its type
    mapping(uint256 => uint256) public typeYields; // maps chef type to yield

    // mint tracking
    uint256 public chefsMintedWithAVAX;
    uint256 public chefsMintedWithPIZZA;
    uint256 public chefsMintedWhitelist;
    uint256 public chefsMintedPromotional;
    uint256 public chefsMinted = 50; // First 50 ids are reserved for the promotional chefs

    // mint control timestamps
    uint256 public startTimeWhitelist;
    uint256 public startTimeAVAX;
    uint256 public startTimePIZZA;

    // PIZZA mint price tracking
    uint256 public currentPIZZAMintCost = 20_000 * 1e18;

    // whitelist
    bytes32 public merkleRoot;
    mapping(address => uint256) public whitelistClaimed;

    // EVENTS

    event onChefCreated(uint256 tokenId);
    event onChefRevealed(uint256 tokenId, uint256 chefType);

    /**
     * requires pizza, chefType oracle address
     * pizza: for liquidity bootstrapping and spending on chefs
     * chefTypeOracleAddress: external chef generator uses secure RNG
     */
    constructor(Pizza _pizza, address _chefTypeOracleAddress, string memory _BASE_URI) ERC721("Pizza Game Chefs", "PIZZA-GAME-CHEF") {
        require(address(_pizza) != address(0));
        require(_chefTypeOracleAddress != address(0));

        // set required contract references
        pizza = _pizza;
        chefTypeOracleAddress = _chefTypeOracleAddress;

        // set base uri
        BASE_URI = _BASE_URI;

        // initialize token yield values for each chef type
        typeYields[CHEF_TYPE] = CHEF_YIELD;
        typeYields[MASTER_CHEF_TYPE] = MASTER_CHEF_YIELD;
    }

    // VIEWS

    // minting status

    function mintingStartedWhitelist() public view returns (bool) {
        return startTimeWhitelist != 0 && block.timestamp >= startTimeWhitelist;
    }

    function mintingStartedAVAX() public view returns (bool) {
        return startTimeAVAX != 0 && block.timestamp >= startTimeAVAX;
    }

    function mintingStartedPIZZA() public view returns (bool) {
        return startTimePIZZA != 0 && block.timestamp >= startTimePIZZA;
    }

    // metadata

    function _baseURI() internal view virtual override returns (string memory) {
        return BASE_URI;
    }

    function getYield(uint256 _tokenId) public view returns (uint256) {
        require (_exists(_tokenId), "token does not exist");
        return typeYields[tokenTypes[_tokenId]];
    }

    function getType(uint256 _tokenId) public view returns (uint256) {
        require (_exists(_tokenId), "token does not exist");
        return tokenTypes[_tokenId];
    }

    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require (_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");
        return string(abi.encodePacked(_baseURI(), "/", tokenId.toString(), ".json"));
    }

    // override

    function isApprovedForAll(address _owner, address _operator) public view override returns (bool) {
        // pizzeria must be able to stake and unstake
        if (pizzeriaAddress != address(0) && _operator == pizzeriaAddress) return true;
        return super.isApprovedForAll(_owner, _operator);
    }

    // ADMIN

    function setPizzeriaAddress(address _pizzeriaAddress) external onlyOwner {
        pizzeriaAddress = _pizzeriaAddress;
    }

    function setPizza(address _pizza) external onlyOwner {
        pizza = Pizza(_pizza);
    }

    function setchefTypeOracleAddress(address _chefTypeOracleAddress) external onlyOwner {
        chefTypeOracleAddress = _chefTypeOracleAddress;
    }

    function setStartTimeWhitelist(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        startTimeWhitelist = _startTime;
    }

    function setStartTimeAVAX(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        startTimeAVAX = _startTime;
    }

    function setStartTimePIZZA(uint256 _startTime) external onlyOwner {
        require (_startTime >= block.timestamp, "startTime cannot be in the past");
        startTimePIZZA = _startTime;
    }

    function setBaseURI(string calldata _BASE_URI) external onlyOwner {
        BASE_URI = _BASE_URI;
    }

    /**
     * @dev merkle root for WL wallets
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        merkleRoot = _merkleRoot;
    }

    /**
     * @dev allows owner to send ERC20s held by this contract to target
     */
    function forwardERC20s(IERC20 _token, uint256 _amount, address target) external onlyOwner {
        _token.safeTransfer(target, _amount);
    }

    /**
     * @dev allows owner to withdraw AVAX
     */
    function withdrawAVAX(uint256 _amount) external payable onlyOwner {
        require(address(this).balance >= _amount, "not enough AVAX");
        address payable to = payable(_msgSender());
        (bool sent, ) = to.call{value: _amount}("");
        require(sent, "Failed to send AVAX");
    }

    // MINTING

    function _createChef(address to, uint256 tokenId) internal {
        require (chefsMinted <= NUM_GEN0_CHEFS + NUM_GEN1_CHEFS, "cannot mint anymore chefs");
        _safeMint(to, tokenId);

        emit onChefCreated(tokenId);
    }

    function _createChefs(uint256 qty, address to) internal {
        for (uint256 i = 0; i < qty; i++) {
            chefsMinted += 1;
            _createChef(to, chefsMinted);
        }
    }

    /**
     * @dev as an anti cheat mechanism, an external automation will generate the NFT metadata and set the chef types via rng
     * - Using an external source of randomness ensures our mint cannot be cheated
     * - The external automation is open source and can be found on pizza game's github
     * - Once the mint is finished, it is provable that this randomness was not tampered with by providing the seed
     * - Chef type can be set only once
     */
    function setChefType(uint256 tokenId, uint256 chefType) external {
        require(_msgSender() == chefTypeOracleAddress, "msgsender does not have permission");
        require(tokenTypes[tokenId] == 0, "that token's type has already been set");
        require(chefType == CHEF_TYPE || chefType == MASTER_CHEF_TYPE, "invalid chef type");

        tokenTypes[tokenId] = chefType;
        emit onChefRevealed(tokenId, chefType);
    }

    /**
     * @dev Promotional GEN0 minting 
     * Can mint maximum of PROMOTIONAL_CHEFS
     * All chefs minted are from the same chefType
     */
    function mintPromotional(uint256 qty, uint256 chefType, address target) external onlyOwner {
        require (qty > 0, "quantity must be greater than 0");
        require ((chefsMintedPromotional + qty) <= PROMOTIONAL_CHEFS, "you can't mint that many right now");
        require(chefType == CHEF_TYPE || chefType == MASTER_CHEF_TYPE, "invalid chef type");

        for (uint256 i = 0; i < qty; i++) {
            chefsMintedPromotional += 1;
            require(tokenTypes[chefsMintedPromotional] == 0, "that token's type has already been set");
            tokenTypes[chefsMintedPromotional] = chefType;
            _createChef(target, chefsMintedPromotional);
        }
    }

    /**
     * @dev Whitelist GEN0 minting
     * We implement a hard limit on the whitelist chefs.
     */
    function mintWhitelist(bytes32[] calldata _merkleProof, uint256 qty) external payable whenNotPaused {
        // check most basic requirements
        require(merkleRoot != 0, "missing root");
        require(mintingStartedWhitelist(), "cannot mint right now");
        require (!mintingStartedAVAX(), "whitelist minting is closed");

        // check if address belongs in whitelist
        bytes32 leaf = keccak256(abi.encodePacked(_msgSender()));
        require(MerkleProof.verify(_merkleProof, merkleRoot, leaf), "this address does not have permission");

        // check more advanced requirements
        require(qty > 0 && qty <= MAXIMUM_MINTS_PER_WHITELIST_ADDRESS, "quantity must be between 1 and 4");
        require((chefsMintedWhitelist + qty) <= WHITELIST_CHEFS, "you can't mint that many right now");
        require((whitelistClaimed[_msgSender()] + qty) <= MAXIMUM_MINTS_PER_WHITELIST_ADDRESS, "this address can't mint any more whitelist chefs");

        // check price
        require(msg.value >= CHEF_PRICE_WHITELIST * qty, "not enough AVAX");

        chefsMintedWhitelist += qty;
        whitelistClaimed[_msgSender()] += qty;

        // mint chefs
        _createChefs(qty, _msgSender());
    }

    /**
     * @dev GEN0 minting
     */
    function mintChefWithAVAX(uint256 qty) external payable whenNotPaused {
        require (mintingStartedAVAX(), "cannot mint right now");
        require (qty > 0 && qty <= 10, "quantity must be between 1 and 10");
        require ((chefsMintedWithAVAX + qty) <= (NUM_GEN0_CHEFS - chefsMintedWhitelist - PROMOTIONAL_CHEFS), "you can't mint that many right now");

        // calculate the transaction cost
        uint256 transactionCost = CHEF_PRICE_AVAX * qty;
        require (msg.value >= transactionCost, "not enough AVAX");

        chefsMintedWithAVAX += qty;

        // mint chefs
        _createChefs(qty, _msgSender());
    }

    /**
     * @dev GEN1 minting 
     */
    function mintChefWithPIZZA(uint256 qty) external whenNotPaused {
        require (mintingStartedPIZZA(), "cannot mint right now");
        require (qty > 0 && qty <= 10, "quantity must be between 1 and 10");
        require ((chefsMintedWithPIZZA + qty) <= NUM_GEN1_CHEFS, "you can't mint that many right now");

        // calculate transaction costs
        uint256 transactionCostPIZZA = currentPIZZAMintCost * qty;
        require (pizza.balanceOf(_msgSender()) >= transactionCostPIZZA, "not enough PIZZA");

        // raise the mint level and cost when this mint would place us in the next level
        // if you mint in the cost transition you get a discount =)
        if(chefsMintedWithPIZZA <= CHEFS_PER_PIZZA_MINT_LEVEL && chefsMintedWithPIZZA + qty > CHEFS_PER_PIZZA_MINT_LEVEL) {
            currentPIZZAMintCost = currentPIZZAMintCost * 2;
        }

        chefsMintedWithPIZZA += qty;

        // spend pizza
        pizza.burn(_msgSender(), transactionCostPIZZA);

        // mint chefs
        _createChefs(qty, _msgSender());
    }

    // Returns information for multiples chefs
    function batchedChefsOfOwner(address _owner, uint256 _offset, uint256 _maxSize) public view returns (ChefInfo[] memory) {
        if (_offset >= balanceOf(_owner)) {
            return new ChefInfo[](0);
        }

        uint256 outputSize = _maxSize;
        if (_offset + _maxSize >= balanceOf(_owner)) {
            outputSize = balanceOf(_owner) - _offset;
        }
        ChefInfo[] memory chefs = new ChefInfo[](outputSize);

        for (uint256 i = 0; i < outputSize; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(_owner, _offset + i); // tokenOfOwnerByIndex comes from IERC721Enumerable

            chefs[i] = ChefInfo({
                tokenId: tokenId,
                chefType: tokenTypes[tokenId]
            });
        }

        return chefs;
    }
}
