// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FakeUSDC is ERC20 {
    constructor() ERC20("Fake USDC", "fUSDC") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
