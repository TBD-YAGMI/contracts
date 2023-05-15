// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./YAGMI.sol";

enum YAGMIStatus {
    EMPTY,
    PROPOSED,
    ACCEPTED,
    MINT_OPEN,
    MINT_CLOSED,
    CANCELED,
    FINISHED
}

struct SponsorProps {
    uint256 ratio; // Under collateralized ratio of sponsor to champion grant
}

struct YAGMIProps {
    address champion; // Address of the champion
    uint64 price; // Price of each token in wei
    uint32 maxSupply; // Max amount of tokens to mint
    address sponsor; // Address of the DAO / sponsor for the champion
    uint32 apy; // % apy, 6 digits of precision (4000000 = 4.000000 %)
    YAGMIStatus status; // Status of tokens
    address erc20; // ERC20 to use for token payments/returns
    uint256 ratioUsed; // Ratio used when proposing
}

contract YAGMIController is AccessControl {
    /** Constants */
    bytes32 public constant SPONSOR = keccak256("SPONSOR_ROLE");
    bytes32 public constant CHAMPION = keccak256("CHAMPION_ROLE");

    /** State Variables */
    uint256 public currentId;
    YAGMI public yagmi;

    mapping(uint256 => YAGMIProps) public tokens;

    mapping(address => SponsorProps) public sponsorProps;
    // Mapping (sponsor => mapping (erc20 => balance) )
    mapping(address => mapping(address => uint256)) public sponsorBalances;

    /** Events */

    /** Functions */
    constructor(address adminWallet) {
        _grantRole(DEFAULT_ADMIN_ROLE, adminWallet);
        _setRoleAdmin(CHAMPION, SPONSOR);
        yagmi = new YAGMI();
    }

    function proposeChampion(
        address champion,
        uint64 price,
        uint32 maxSupply,
        uint32 apy,
        address erc20
    ) public onlyRole(SPONSOR) {

        // require (Sponsor can propose a champion)

        tokens[currentId] = YAGMIProps(
            champion,
            price,
            maxSupply,
            msg.sender,
            apy,
            YAGMIStatus.PROPOSED,
            erc20,
            sponsorProps[msg.sender].ratio
        );
        grantRole(CHAMPION, champion);
        currentId++;

        // Move money
    }

    // Mint function ( require totalSupply(id)+amount <= maxSupply(id) )
    function mint(uint256 id, uint256 amount) public {
        // TODO: require consdiciones del mint
        require(tokens[id].status == YAGMIStatus.MINT_OPEN);

        yagmi.mint(msg.sender, id, amount, "");
    }

    // TODO:
    //      Burn function
    //      setUri function
    //      setup initial tokenId properties (maxSupply, return %, etc)
}
