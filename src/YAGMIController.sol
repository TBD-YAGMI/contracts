// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./YAGMI.sol";

enum YAGMIStatus {
    EMPTY,
    PROPOSED,
    // ACCEPTED,
    MINT_OPEN,
    MINT_CLOSED,
    THRESHOLD_MET,
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
    address champion; // 160 | Address of the champion
    uint64 price; //  64 | Price of each token in wei
    uint32 maxSupply; //  32 | Max amount of tokens to mint
    // 256 bits -> 1 register
    address sponsor; // 160 | Address of the DAO / sponsor for the champion
    uint32 apy; //  32 | % apy, 6 digits of precision (4000000 = 4.000000 %)
    uint16 interestProportion; // 16 | in 1/1000 of apy, to apply daily interest for late payments
    uint16 daysToFirstPayment; //  16 | Days for first payment of champion starting from the date the loan was withdrawn
    uint16 paymentFreqInDays; //  16 | Payments frequency for the champion
    uint8 numberOfpayments; //   8 | Number of payments the champion is going to do to return the loan
    uint8 ratioUsed; //   8 | Ratio used when proposing the champion
    // 256 bits -> 1 register
    address erc20; // 160 | ERC20 to use for token payments/returns
    YAGMIStatus status; //   8 | Status of tokens
}

contract YAGMIController is AccessControl {
    /** Constants */
    bytes32 public constant SPONSOR = keccak256("SPONSOR_ROLE");
    bytes32 public constant CHAMPION = keccak256("CHAMPION_ROLE");

    /** State Variables */

    // current NFT id counter
    uint256 public currentId;
    // Interest Rate for late payments of champion, as 1/1000 parts of apy
    uint16 public interestProportion;
    // NFT Contract
    YAGMI public yagmi;
    // Properties for each NFT TokenId
    mapping(uint256 => YAGMIProps) public tokens;
    // Profile for each user
    mapping(address => ProfileProps) public profiles;
    // Properties for each champinon
    mapping(address => ChampionProps) public champions;
    // Properties for each sponsor
    mapping(address => SponsorProps) public sponsors;
    // Balance available of each ERC20, for each sponsor (ERC20 => sponsor => balance)
    mapping(address => mapping(address => uint256))
        public sponsorAvailableBalance;
    // Balance locked of each ERC20, for each sponsor (ERC20 => sponsor => balance)
    mapping(address => mapping(address => uint256)) public sponsorLockedBalance;

    /** Events */
    event NewChampion(
        address indexed sponsor,
        address indexed champion,
        uint256 indexed tokenId,
        uint256 depositAmount
    );

    event MintOpen(uint256 indexed tokenId);

    event CanceledSponsorship(
        address indexed sponsor,
        address indexed champion,
        uint256 indexed tokenId
    );

    event ThresholdMet(uint256 indexed tokenId);

    event NewInterestProportion(
        uint16 indexed oldInterestProportion,
        uint16 indexed newInterestProportion
    );

    /** Functions */
    constructor(address adminWallet) {
        _grantRole(DEFAULT_ADMIN_ROLE, adminWallet);
        _setRoleAdmin(CHAMPION, SPONSOR);
        yagmi = new YAGMI();
        interestProportion = 20; // Starts at 2% (Ex: if apy=10% =>  Daily Interest is 0.2%)
    }

    function setInterestProportion(
        uint16 newInterestProportion
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        interestProportion = newInterestProportion;
        emit NewInterestProportion(interestProportion, newInterestProportion);
    }

    function proposeChampion(
        address champion,
        uint64 price,
        uint32 maxSupply,
        uint256 depositAmount,
        address erc20,
        uint32 apy,
        uint16 daysToFirstPayment,
        uint16 paymentFreqInDays,
        uint8 numberOfpayments
    ) public onlyRole(SPONSOR) returns (uint256 tokenId) {
        SponsorProps memory sponsor = sponsors[msg.sender];
        // Check ratio of sponsor for champion
        require(maxSupply * price == sponsor.ratio * depositAmount);

        // Set Props for the NFT of the champion
        tokenId = currentId;
        tokens[currentId] = YAGMIProps(
            champion,
            price,
            maxSupply,
            msg.sender,
            apy,
            interestProportion,
            daysToFirstPayment,
            paymentFreqInDays,
            numberOfpayments,
            sponsors[msg.sender].ratio,
            erc20,
            YAGMIStatus.PROPOSED
        );
        grantRole(CHAMPION, champion);
        currentId++;

        // Update balanceLocked of sponsor
        sponsorLockedBalance[erc20][msg.sender] += depositAmount;

        // Verify we have enough allowance to receive the depositAmount
        uint256 currentAllowance = IERC20(erc20).allowance(
            msg.sender,
            address(this)
        );
        if (currentAllowance < depositAmount)
            require(
                IERC20(erc20).approve(address(this), depositAmount),
                "Approve failed"
            );

        // Receive the depositAmount of erc20 tokens
        require(
            IERC20(erc20).transferFrom(
                msg.sender,
                address(this),
                depositAmount
            ),
            "ERC20 transfer failed"
        );

        // Emit events
        emit NewChampion(msg.sender, champion, tokenId, depositAmount);
    }

    function openMint(uint256 tokenId) public onlyRole(SPONSOR) {
        // Check that sponsor can open this mint
        YAGMIProps memory nftProps = tokens[tokenId];
        require(nftProps.sponsor == msg.sender, "Token has another sponsor");
        require(
            nftProps.status == YAGMIStatus.PROPOSED,
            "Not in PROPOSED Status"
        );

        // Open mint for token
        tokens[tokenId].status = YAGMIStatus.MINT_OPEN;

        // Emit events
        emit MintOpen(tokenId);
    }

    function cancelSponsorship(uint256 tokenId) public onlyRole(SPONSOR) {
        // Check that sponsor can open this mint
        YAGMIProps memory nftProps = tokens[tokenId];
        require(nftProps.sponsor == msg.sender, "Token has another sponsor");
        require(
            nftProps.status == YAGMIStatus.MINT_OPEN,
            "Not in MINT_OPEN Status"
        );
        require(
            yagmi.totalSupply(tokenId) == 0,
            "Can't cancel w/totalSupply > 0"
        );

        // Open mint for token
        tokens[tokenId].status = YAGMIStatus.CANCELED;

        // Emit events
        emit CanceledSponsorship(msg.sender, nftProps.champion, tokenId);
    }

    // Mint function ( require totalSupply(id)+amount <= maxSupply(id) )
    function mint(uint256 id, uint256 amount) public {
        YAGMIProps memory nftProps = tokens[id];

        require(nftProps.status == YAGMIStatus.MINT_OPEN, "Minting Not Open");
        uint256 currentSupply = yagmi.totalSupply(id);
        require(
            nftProps.maxSupply >= currentSupply + amount,
            "Amount exceeds maxSupply left"
        );

        yagmi.mint(msg.sender, id, amount, "");

        // Update status if Threshold is met
        if (nftProps.maxSupply == currentSupply + amount) {
            tokens[id].status = YAGMIStatus.THRESHOLD_MET;
            // emit events
            emit ThresholdMet(id);
        }

        // Verify we have enough allowance to receive the depositAmount
        uint256 totalPrice = nftProps.price * amount;
        uint256 currentAllowance = IERC20(nftProps.erc20).allowance(
            msg.sender,
            address(this)
        );
        if (currentAllowance < totalPrice)
            require(
                IERC20(nftProps.erc20).approve(address(this), totalPrice),
                "Approve failed"
            );

        // Receive the depositAmount of erc20 tokens
        require(
            IERC20(nftProps.erc20).transferFrom(
                msg.sender,
                address(this),
                totalPrice
            ),
            "ERC20 transfer failed"
        );
    }

    // DONE: setup initial tokenId properties (maxSupply, return %, etc)
    // DONE: mint function
    // DONE: ERC20 allowance before mint (Supporter approves ERC20 to spend)

    // IN PROGRESS: changeTokenIdStatus (PROPOSED -> MINT_OPEN -> ... -> FINISHED)

    // TODO: Burn function to recover investment and its conditions
    // TODO: setUri function
    // TODO: Chainlink trigger Functions
    // TODO: Incentives of different apy for staking
}
