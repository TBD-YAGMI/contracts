// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./YAGMI.sol";

enum YAGMIStatus {
    EMPTY,
    PROPOSED,
    MINT_OPEN,
    THRESHOLD_MET,
    LOANED,
    BURN_OPEN, // Also means Sponsor Deposit is Claimable
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
    uint32 maxSupply; // Max amount of tokens to mint
    uint32 apy; // % apy, 6 digits of precision (4000000 = 4.000000 %)
    uint16 daysToFirstPayment; // Days for first payment of champion starting from the date the loan was withdrawn
    uint16 paymentFreqInDays; // Payments frequency for the champion
    // 256 bits -> 1 register

    uint256 price; // Price of each token in wei
    // 256 bits -> 1 register

    uint256 loanTaken; // Timestamp of moment the champion withdrew the loan
    // 256 bits -> 1 register

    uint256 interestsAccrued; // Amount of ERC20 payed as interest by champion
    // 256 bits -> 1 register

    uint256 amountReturned; // Amount of ERC20 returned from base payments by champion
    // 256 bits -> 1 register

    uint256 amountClaimed; // Amount of ERC20 claimed from base payments
    // 256 bits -> 1 register

    address sponsor; // Address of the DAO / sponsor for the champion
    // 160 bits -> 1 register

    address erc20; // ERC20 to use for token payments/returns
    uint16 interestProportion; // in 1/1000 of apy, to apply daily interest for late payments
    uint16 numberOfPayments; // Number of payments the champion is going to do to return the loan
    uint16 paymentsDone; // Number of payments the champion already payed back
    uint16 ratio; // Ratio used when proposing the champion
    YAGMIStatus status; // Status of tokens
    // 232 bits -> 1 register
}

uint256 constant PRECISION = 10_000_000;

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
    // Properties for each champion
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

    event LoanWithdrawn(
        address indexed champion,
        uint256 indexed tokenId,
        uint256 indexed timestamp,
        uint256 amount
    );

    event BurnOpen(uint256 indexed tokenId, uint256 indexed timestamp);

    event PaymentReturned(
        address indexed champion,
        uint256 indexed tokenId,
        uint16 indexed payment,
        uint256 pay,
        uint256 interests
    );
    event ClaimedByBurn(
        address indexed investor,
        uint256 indexed tokenId,
        uint256 tokenAmount,
        uint256 pay,
        uint256 interests
    );
    event ClaimedDonations(
        address indexed champion,
        uint256 indexed tokenId,
        claimedPay,
        claimedInterests
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
        uint32 maxSupply,
        uint32 apy,
        uint16 paymentFreqInDays,
        uint16 numberOfPayments,
        uint256 price,
        address erc20,
        uint16 daysToFirstPayment
    ) public onlyRole(SPONSOR) returns (uint256 tokenId) {
        SponsorProps memory sponsor = sponsors[msg.sender];
        uint256 depositAmount = (price * maxSupply) / sponsor.ratio;

        // Set Props for the NFT of the champion
        tokenId = currentId;
        tokens[currentId].champion = champion;
        tokens[currentId].price = price;
        tokens[currentId].maxSupply = maxSupply;
        tokens[currentId].sponsor = msg.sender;
        tokens[currentId].apy = apy;
        tokens[currentId].interestProportion = interestProportion;
        tokens[currentId].daysToFirstPayment = daysToFirstPayment;
        tokens[currentId].paymentFreqInDays = paymentFreqInDays;
        tokens[currentId].numberOfPayments = numberOfPayments;
        tokens[currentId].ratio = sponsors[msg.sender].ratio;
        tokens[currentId].erc20 = erc20;
        tokens[currentId].status = YAGMIStatus.PROPOSED;

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

    function withdrawLoan(uint256 tokenId) public onlyRole(CHAMPION) {
        // check the tokenId is for msg.sender and the threshold has been met
        YAGMIProps memory nftProps = tokens[tokenId];
        require(
            nftProps.champion == msg.sender,
            "Not the champion of the tokenId"
        );
        require(
            nftProps.status == YAGMIStatus.THRESHOLD_MET,
            "Not in Threshold met status"
        );

        tokens[tokenId].status = YAGMIStatus.LOANED;
        tokens[tokenId].loanTaken = block.timestamp;

        // Approve loanAmount of erc20 tokens to msg.sender
        uint256 loanAmount = nftProps.price * nftProps.maxSupply;

        // Tranfer loanAmount of erc20 tokens to champion
        require(
            IERC20(nftProps.erc20).transfer(msg.sender, loanAmount),
            "ERC20 transfer failed"
        );

        emit LoanWithdrawn(msg.sender, block.timestamp, tokenId, loanAmount);
    }

    // How much is owed for a given number of payment (returns pay + interests separately)
    function amountsOwed(
        uint256 tokenId,
        uint256 timestamp,
        uint16 payment
    ) public view returns (uint256 pay, uint256 interests) {
        YAGMIProps memory nftProps = tokens[tokenId];

        uint256 baseOwed = _baseOwed(
            tokenId,
            nftProps.price,
            nftProps.maxSupply,
            payment,
            nftProps.paymentsDone,
            nftProps.numberOfPayments
        );

        if (baseOwed == 0) return (0, 0);

        pay = baseOwed + (baseOwed * nftProps.apy) / PRECISION;

        interests = _interestOwed(
            pay,
            timestamp,
            nftProps.loanTaken,
            uint256(nftProps.apy) * uint256(nftProps.interestProportion / 1000),
            payment,
            nftProps.daysToFirstPayment,
            nftProps.paymentFreqInDays
        );
    }

    function _baseOwed(
        uint256 tokenId,
        uint256 price,
        uint32 maxSupply,
        uint16 payment,
        uint16 paymentsDone,
        uint16 numberOfPayments
    ) internal pure returns (uint256) {
        // If number of payment out of range, return 0
        if (payment <= paymentsDone || payment > numberOfPayments) return 0;

        // Calculate original base payment
        uint256 basePay = (price * maxSupply) / numberOfPayments;

        uint256 totalBaseReturned = basePay * paymentsDone;

        // Check if there has been changes in the supply of the tokens that lower the debt
        uint256 tokensLeft = yagmi.totalSupply(tokenId);
        uint256 loanedBaseLeft = tokensLeft * price;

        // If payed more or equal than is owed, return 0
        if (totalBaseReturned >= loanedBaseLeft) return 0;

        // If debt left is less than a base payment, return only debt
        return
            (loanedBaseLeft - totalBaseReturned < basePay)
                ? loanedBaseLeft - totalBaseReturned
                : basePay;
    }

    function _interestOwed(
        uint256 basePay,
        uint256 timestamp,
        uint256 debtTakenDay,
        uint256 dailyInterestPoints,
        uint16 payment,
        uint16 daysTo1stPayment,
        uint16 paymentFreq
    ) internal pure returns (uint256) {
        // Due date for Payment
        uint256 dueDate = debtTakenDay +
            uint256(daysTo1stPayment) *
            1 days +
            (uint256(payment) - 1) *
            uint256(paymentFreq) *
            1 days;

        uint256 daysLate = (timestamp <= dueDate)
            ? 0
            : (timestamp - dueDate) / 1 days;

        // Return the amount owed for this payment + apy (+ interests in case of late canceling)
        return
            (basePay * (dailyInterestPoints ** daysLate)) / // installment + apy
            (PRECISION ** daysLate); // interest,  to the power of days late
    }

    function setURI(string memory newuri) public onlyRole(DEFAULT_ADMIN_ROLE) {
        yagmi.setURI(newuri);
    }

    function returnPayment(uint256 tokenId) public onlyRole(CHAMPION) {
        YAGMIProps memory nftProps = tokens[tokenId];
        // Only champion of the tokenId can pay back
        require(
            nftProps.champion == msg.sender,
            "Not the champion of the tokenId"
        );

        // Can only pay in order
        uint16 payment = nftProps.paymentsDone + 1;

        // Amount owed + interest owed
        (uint256 pay, uint256 interests) = amountsOwed(
            tokenId,
            block.timestamp,
            payment
        );

        // Calculate original base payment without changes
        uint256 basePay = (nftProps.price * nftProps.maxSupply) /
            nftProps.numberOfPayments;

        // Check if this payment finishes the debt
        uint256 totalReturnedAfterPayment = basePay * payment;
        uint256 tokensLeft = yagmi.totalSupply(tokenId);
        uint256 updatedLoanedAmount = tokensLeft * nftProps.price;

        // If this cancels the debt, update state
        if (totalReturnedAfterPayment >= updatedLoanedAmount) {
            // update state
            tokens[tokenId].status = YAGMIStatus.BURN_OPEN;
            emit BurnOpen(tokenId, block.timestamp);
        }

        if (pay == 0) return;

        // Update state
        tokens[tokenId].paymentsDone = payment;
        tokens[tokenId].amountReturned += pay;
        tokens[tokenId].interestsAccrued += interests;

        uint256 totalPayment = pay + interests;

        // Verify we have enough allowance to receive the payment
        uint256 currentAllowance = IERC20(nftProps.erc20).allowance(
            msg.sender,
            address(this)
        );
        if (currentAllowance < totalPayment)
            require(
                IERC20(nftProps.erc20).approve(address(this), totalPayment),
                "Approve failed"
            );

        // Receive the amountToPay of erc20 tokens
        require(
            IERC20(nftProps.erc20).transferFrom(
                msg.sender,
                address(this),
                totalPayment
            ),
            "ERC20 transfer failed"
        );

        emit ReturnedPayment(msg.sender, tokenId, payment, pay, interests);
    }

    function burnToClaim(uint256 tokenId) public {
        YAGMIProps memory nftProps = tokens[tokenId];
        require(
            nftProps.status == YAGMIStatus.BURN_OPEN,
            "Burn to withdraw not open"
        );

        uint256 balance = yagmi.balanceOf(msg.sender, tokenId);
        require(balance > 0, "Balance is 0. No tokens to burn");

        uint256 totalSupply = yagmi.totalSupply(tokenId);
        // totalSupply can't be 0 because balance > 0

        uint256 basePrice = nftProps.price +
            (nftProps.price * nftProps.apy) /
            PRECISION;

        uint256 baseClaim = basePrice * balance;

        uint256 interestsClaim = balance == totalSupply
            ? nftProps.interestsAccrued
            : (nftProps.interestsAccrued * balance) / totalSupply;

        require(
            nftProps.amountReturned >= nftProps.amountClaimed + baseClaim,
            "Not enough balance to claim"
        );
        // update state
        tokens[tokenId].interestsAccrued -= interestsClaim;
        tokens[tokenId].amountClaimed += baseClaim;

        if (balance == totalSupply)
            tokens[tokenId].status = YAGMIStatus.FINISHED;

        // burn tokens
        yagmi.burnOnlyOwner(msg.sender, tokenId, balance);

        // transfer erc20
        // Tranfer (balance * unitPrice) of erc20 tokens to champion
        require(
            IERC20(nftProps.erc20).transfer(
                msg.sender,
                baseClaim + interestsClaim
            ),
            "ERC20 transfer failed"
        );

        emit ClaimedByBurn(
            msg.sender,
            tokenId,
            balance,
            baseClaim,
            interestsClaim
        );
    }

    function claimDonations(tokenId) public onlyRole(CHAMPION) {
        YAGMIProps memory nftProps = tokens[tokenId];

        require(
            nftProps.champion == msg.sender,
            "Not the champion of the tokenId"
        );

        require(
            nftProps.status == YAGMIStatus.FINISHED,
            "Not in Finished status"
        );

        uint256 interestsDust = nftProps.interestsAccrued;
        uint256 baseDust = nftProps.amountReturned - nftProps.amountClaimed;

        require(baseDust + interestsDust > 0, "No Amount Left to Claim");

        // update state
        tokens[tokenId].interestsAccrued = 0;
        tokens[tokenId].amountClaimed = nftProps.amountReturned;

        // transfer erc20
        // Tranfer (balance * unitPrice) of erc20 tokens to champion
        require(
            IERC20(nftProps.erc20).transfer(
                msg.sender,
                baseDust + interestsDust
            ),
            "ERC20 transfer failed"
        );

        emit ClaimedDonations(msg.sender, tokenId, baseDust, interestsDust);
    }
    // ---
    // DONE: setup initial tokenId properties (maxSupply, return %, etc)
    // DONE: mint function
    // DONE: ERC20 allowance before mint (Supporter approves ERC20 to spend)
    // DONE: setUri function
    // DONE: amountsOwed function
    // DONE: withdrawLoan function
    // DONE: payBack function
    // DONE: Burn function to recover investment and its conditions
    // DONE: Claim donations by champion

    // DONE: changeTokenIdStatus (PROPOSED -> MINT_OPEN -> ... -> FINISHED)
    //    DONE:        EMPTY -> PROPOSED -> MINT_OPEN -> CANCELED
    //    DONE: EMPTY -> PROPOSED -> MINT_OPEN -> THRESHOLD_MET -> LOANED -> BURN_OPEN -> FINISHED

    // TODO: Move requires to custom errors
    // TODO: Chainlink trigger Functions
    // TODO: Incentives of different apy for staking
}
