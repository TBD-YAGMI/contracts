// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./YAGMI.sol";

enum YAGMIStatus {
    EMPTY,
    PROPOSED,
    // ACCEPTED,
    MINT_OPEN,
    MINT_CLOSED,
    ONGOING,
    FINISHED,
    CANCELED
}

struct ProfileProps {
    uint256 registerDate;
    uint256 birthDate;
    string name;
    string description;
    string avatar;
    address wallet;
}

struct SponsorProps {
    uint64 proposed;
    uint32 sponsored;
    uint16 sponsoring;
    uint8 ratio; // Under collateralized ratio of sponsor to champion grant
}

struct ChampionProps {
    uint16 proposed;
    uint16 sponsored;
    uint16 payedBack;
    uint16 canceled;
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

    mapping(address => ProfileProps) public profiles;
    mapping(address => ChampionProps) public champions;
    mapping(address => SponsorProps) public sponsors;
    mapping(address => mapping(address => uint256)) sponsorBalance;
    mapping(address => mapping(address => uint256)) sponsorLocked;

    // Mapping (sponsor => mapping (erc20 => balance) )

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
        uint256 balance = sponsorBalance[msg.sender][erc20];
        SponsorProps memory sponsor = sponsors[msg.sender];
        require(maxSupply * price <= sponsor.ratio * balance);

        tokens[currentId] = YAGMIProps(
            champion,
            price,
            maxSupply,
            msg.sender,
            apy,
            YAGMIStatus.PROPOSED,
            erc20,
            sponsors[msg.sender].ratio
        );
        grantRole(CHAMPION, champion);
        currentId++;

        // Move money
    }

    // Mint function ( require totalSupply(id)+amount <= maxSupply(id) )
    function mint(uint256 id, uint256 amount) public {
        // TODO: require mint conditions
        // TODO: ERC20 transfer

        require(tokens[id].status == YAGMIStatus.MINT_OPEN);

        yagmi.mint(msg.sender, id, amount, "");
    }

    // IN PROGRESS: setup initial tokenId properties (maxSupply, return %, etc)
    // IN PROGRESS: mint function

    // TODO: ERC20 allowance before mint (Supporter approves ERC20 to spend)
    // TODO: Burn function and its conditions
    // TODO: setUri function
    // TODO: changeTokenIdStatus (PROPOSED -> MINT_OPEN -> ... -> FINISHED)
    // TODO: Chainlink trigger Functions
    // TODO: Incentives of different apy for staking
}
