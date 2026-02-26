// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title MockUSDC — Testnet USDC for FoodySwap demo
/// @notice Simple ERC20 with 6 decimals and public mint for testing
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}

    /// @notice Anyone can mint on testnet
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
