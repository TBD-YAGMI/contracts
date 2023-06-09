// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "../src/YAGMIController.sol";
import "../src/YAGMI.sol";
import "../src/FakeUSDC.sol";

contract YAGMIControllerTest is Test {
    YAGMIController public yc;
    FakeUSDC public fUSDC;

    bytes32 public constant ADMIN_ROLE = 0x00;

    address admin = address(1);
    address sponsor = address(2);
    address champion = address(3);
    address investor = address(4);
    address anon = address(5);

    function setUp() public {
        fUSDC = new FakeUSDC();
        yc = new YAGMIController(admin);
        fundAccounts();
        approveForAll();
        // printAccounts();
    }

    function printAccounts() internal view {
        console.log("ADMIN: ", admin);
        console.log("SPONSOR: ", sponsor);
        console.log("CHAMPION: ", champion);
        console.log("INVESTOR: ", investor);
    }

    function fundAccounts() internal {
        fUSDC.mint(sponsor, 1_000_000 ether);
        fUSDC.mint(champion, 1_000_000 ether);
        fUSDC.mint(investor, 1_000_000 ether);
    }

    function approveForAll() internal {
        vm.prank(sponsor);
        fUSDC.approve(address(yc), type(uint256).max);
        vm.prank(champion);
        fUSDC.approve(address(yc), type(uint256).max);
        vm.prank(investor);
        fUSDC.approve(address(yc), type(uint256).max);
    }

    function addSponsor() internal {
        vm.prank(admin);
        yc.addSponsor(sponsor, 1);
    }

    function testAddSponsor() public {
        addSponsor();
        assertEq(yc.sponsorsRatio(sponsor), 1);
    }

    function proposeChampion() internal {
        vm.prank(sponsor);
        yc.proposeChampion(
            champion,
            20,
            10_000_000,
            2,
            4,
            50 ether,
            address(fUSDC),
            2,
            30
        );
    }

    function testProposeChampion() public {
        addSponsor();
        proposeChampion();
        (
            address nftchampion,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            YAGMIStatus nftstatus,
            ,

        ) = yc.tokens(0);
        assertEq(nftchampion, champion);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.PROPOSED);
        assertEq(status, statusCode);
    }

    function openMint() internal {
        vm.prank(sponsor);
        yc.openMint(0);
    }

    function testOpenMint() public {
        addSponsor();
        proposeChampion();
        openMint();

        (, , , , , , , , , , , , , , , , , YAGMIStatus nftstatus, , ) = yc
            .tokens(0);

        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.MINT_OPEN);
        assertEq(status, statusCode);
    }

    function mint(uint256 tokenId, uint256 amount) internal {
        vm.prank(investor);
        yc.mint(tokenId, amount);
    }

    function testMint() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);

        YAGMI y = yc.yagmi();
        uint256 supply = y.totalSupply(0);
        assertEq(supply, 20);

        (, , , , , , , , , , , , , , , , , YAGMIStatus nftstatus, , ) = yc
            .tokens(0);

        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.THRESHOLD_MET);
        assertEq(status, statusCode);
    }

    function withdrawLoan(uint256 tokenId) internal {
        vm.prank(champion);
        yc.withdrawLoan(tokenId);
    }

    function testWithdrawLoan() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);
        uint256 oldBalance = fUSDC.balanceOf(champion);
        withdrawLoan(0);
        uint256 newBalance = fUSDC.balanceOf(champion);

        (
            ,
            uint32 nftmaxSupply,
            ,
            ,
            ,
            uint256 nftprice,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            YAGMIStatus nftstatus,
            ,

        ) = yc.tokens(0);

        assertEq(newBalance - oldBalance, nftprice * nftmaxSupply);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.LOANED);
        assertEq(status, statusCode);
    }

    function returnPayment(uint256 tokenId) internal {
        vm.prank(champion);
        yc.returnPayment(tokenId);
    }

    function testReturnPayment() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);
        withdrawLoan(0);

        vm.warp(block.timestamp + TIMEFRAME * 1);
        (uint256 baseOwed, uint256 interestOwed) = yc.amountsOwed(
            0,
            block.timestamp,
            1
        );

        uint256 oldBalance = fUSDC.balanceOf(champion);
        returnPayment(0);
        uint256 newBalance = fUSDC.balanceOf(champion);
        assertEq(oldBalance - newBalance, baseOwed + interestOwed);

        (, , , , , , , , , , , , , , , , uint16 nftpaymentsDone, , , ) = yc
            .tokens(0);

        assertEq(nftpaymentsDone, 1);
    }

    function testLateReturnPayment() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);
        withdrawLoan(0);

        vm.warp(block.timestamp + TIMEFRAME * 1);
        returnPayment(0);

        vm.warp(block.timestamp + TIMEFRAME * 4);
        (uint256 baseOwed, uint256 interestOwed) = yc.amountsOwed(
            0,
            block.timestamp,
            2
        );

        console.log("baseOwed: ", baseOwed / 1 ether);
        console.log("interestOwed: ", interestOwed / 1 ether);

        uint256 oldBalance = fUSDC.balanceOf(champion);
        returnPayment(0);
        uint256 newBalance = fUSDC.balanceOf(champion);
        assertEq(oldBalance - newBalance, baseOwed + interestOwed);

        (, , , , , , , , , , , , , , , , uint16 nftpaymentsDone, , , ) = yc
            .tokens(0);

        assertEq(nftpaymentsDone, 2);
    }

    function testDebtPayed() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);
        withdrawLoan(0);

        uint256 oldBalance = fUSDC.balanceOf(champion);

        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);

        uint256 newBalance = fUSDC.balanceOf(champion);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 nftinterestsAccrued,
            uint256 nftamountReturned,
            ,
            ,
            ,
            ,
            ,
            ,
            uint16 nftpaymentsDone,
            YAGMIStatus nftstatus,
            ,

        ) = yc.tokens(0);

        console.log("Total from installments: ", nftamountReturned / 1 ether);
        console.log("Total from interests: ", nftinterestsAccrued / 1 ether);
        console.log(
            "Total balance used: ",
            (oldBalance - newBalance) / 1 ether
        );
        assertEq(
            oldBalance - newBalance,
            nftamountReturned + nftinterestsAccrued
        );
        assertEq(nftpaymentsDone, 4);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.BURN_OPEN);
        assertEq(status, statusCode);
    }

    function testDebtPayedLate() public {
        addSponsor();
        proposeChampion();
        openMint();
        mint(0, 20);
        withdrawLoan(0);

        uint256 oldBalance = fUSDC.balanceOf(champion);

        vm.warp(block.timestamp + TIMEFRAME * 2);
        (uint256 baseOwed, uint256 interestOwed) = yc.amountsOwed(
            0,
            block.timestamp,
            2
        );

        console.log("baseOwed: ", baseOwed / 1 ether);
        console.log("interestOwed: ", interestOwed / 1 ether);

        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);
        vm.warp(block.timestamp + TIMEFRAME * 2);
        returnPayment(0);

        uint256 newBalance = fUSDC.balanceOf(champion);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 nftinterestsAccrued,
            uint256 nftamountReturned,
            ,
            ,
            ,
            ,
            ,
            ,
            uint16 nftpaymentsDone,
            YAGMIStatus nftstatus,
            ,

        ) = yc.tokens(0);

        console.log("Total from installments: ", nftamountReturned / 1 ether);
        console.log("Total from interests: ", nftinterestsAccrued / 1 ether);
        console.log(
            "Total balance used: ",
            (oldBalance - newBalance) / 1 ether
        );
        assertEq(
            oldBalance - newBalance,
            nftamountReturned + nftinterestsAccrued
        );
        assertEq(nftpaymentsDone, 4);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.BURN_OPEN);
        assertEq(status, statusCode);
    }

    function claimDeposit(uint256 tokenId) internal {
        vm.prank(sponsor);
        yc.claimDeposit(tokenId);
    }

    function testClaimDeposit() public {
        addSponsor();

        uint256 oldBalance = fUSDC.balanceOf(sponsor);

        proposeChampion();
        openMint();
        mint(0, 20);
        withdrawLoan(0);
        returnPayment(0);
        returnPayment(0);
        returnPayment(0);
        returnPayment(0);

        claimDeposit(0);

        uint256 newBalance = fUSDC.balanceOf(sponsor);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            YAGMIStatus nftstatus,
            bool nftclaimedDeposit,

        ) = yc.tokens(0);

        console.log("Original Balance: ", oldBalance / 1 ether);
        console.log("New Balance: ", newBalance / 1 ether);
        assertEq(oldBalance, newBalance);
        assertEq(nftclaimedDeposit, true);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.BURN_OPEN);
        assertEq(status, statusCode);
    }

    function burnToClaim(uint256 tokenId) internal {
        vm.prank(investor);
        yc.burnToClaim(tokenId);
    }

    function testBurnToClaim() public {
        addSponsor();
        proposeChampion();
        openMint();

        uint256 oldBalance = fUSDC.balanceOf(investor);
        mint(0, 20);
        uint256 midBalance = fUSDC.balanceOf(investor);

        withdrawLoan(0);
        returnPayment(0);
        returnPayment(0);
        returnPayment(0);
        returnPayment(0);
        claimDeposit(0);
        burnToClaim(0);

        uint256 newBalance = fUSDC.balanceOf(investor);

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 nftamountClaimed,
            ,
            ,
            ,
            ,
            ,
            ,
            YAGMIStatus nftstatus,
            ,

        ) = yc.tokens(0);

        console.log("Original Balance: ", oldBalance / 1 ether);
        console.log("Middle Balance: ", midBalance / 1 ether);
        console.log("New Balance: ", newBalance / 1 ether);
        assertEq(newBalance, midBalance + nftamountClaimed);
        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.FINISHED);
        assertEq(status, statusCode);
    }

    function printStatus(uint256 tokenId) internal view {
        (, , , , , , , , , , , , , , , , , YAGMIStatus nftstatus, , ) = yc
            .tokens(tokenId);
        console.log("Time: ", block.timestamp);
        console.log("Status: ", uint8(nftstatus));
    }

    function testUnmetThreshold() public {
        addSponsor();
        proposeChampion();
        openMint();

        vm.warp(block.timestamp + TIMEFRAME * 29);
        yc.performUpkeep("");
        printStatus(0);
        vm.warp(block.timestamp + TIMEFRAME * 1);
        yc.performUpkeep("");
        printStatus(0);

        (, , , , , , , , , , , , , , , , , YAGMIStatus nftstatus, , ) = yc
            .tokens(0);

        uint8 status = uint8(nftstatus);
        uint8 statusCode = uint8(YAGMIStatus.THRESHOLD_UNMET);
        assertEq(status, statusCode);
    }

    function burnToRecover(uint256 tokenId) internal {
        vm.prank(investor);
        yc.burnToRecover(tokenId);
    }

    function testBurnToRecover() public {
        addSponsor();
        proposeChampion();

        openMint();
        uint256 oldBalance = fUSDC.balanceOf(investor);
        mint(0, 10);
        vm.warp(block.timestamp + TIMEFRAME * 29);
        yc.performUpkeep("");
        vm.warp(block.timestamp + TIMEFRAME * 1);
        yc.performUpkeep("");
        burnToRecover(0);
        uint256 newBalance = fUSDC.balanceOf(investor);
        assertEq(oldBalance, newBalance);
    }

    function testGrabAdmin() public {
        vm.prank(anon);
        yc.grabAdmin();

        assertEq(yc.hasRole(ADMIN_ROLE, anon), true);
    }
}

// (
//     address nftchampion,
//     uint32 nftmaxSupply,
//     uint32 nftapy,
//     uint16 nftinterestProportion,
//     uint16 nftratio,
//     uint256 nftprice,
//     uint256 nftmintStart,
//     uint256 nftloanTaken,
//     uint256 nftinterestsAccrued,
//     uint256 nftamountReturned,
//     uint256 nftamountClaimed,
//     address nfterc20,
//     uint16 nftmaxMintDays,
//     uint16 nftdaysToFirstPayment,
//     uint16 nftpaymentFreqInDays,
//     uint16 nftnumberOfPayments,
//     uint16 nftpaymentsDone,
//     YAGMIStatus nftstatus,
//     bool nftclaimedDeposit,
//     address nftsponsor
// ) = yc.tokens(0);
