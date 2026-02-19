// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Mock of the on-chain FoodyeCoin for testing.
///         Replicates the MINTER_ROLE-based mint() interface.
contract MockFoodyToken is ERC20 {
    mapping(address => bool) public minters;
    address public admin;

    constructor() ERC20("Foody Token", "FOODY", 18) {
        admin = msg.sender;
        minters[msg.sender] = true;
    }

    function mint(address to, uint256 amount) external {
        require(minters[msg.sender], "Not a minter");
        _mint(to, amount);
    }

    function grantMinterRole(address account) external {
        require(msg.sender == admin, "Not admin");
        minters[account] = true;
    }
}
