// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./YAGMI.sol";

contract YAGMIController is AccessControl{
    YAGMI public yagmi;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        yagmi = new YAGMI();
    }

    // TODO:
    //      Mint function ( require totalSupply(id)+amount <= maxSupply(id) )
    //      Burn function
    //      setUri function
    //      setup initial tokenId properties (maxSupply, return %, etc)

}
