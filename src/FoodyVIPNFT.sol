// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";
import {Owned} from "solmate/src/auth/Owned.sol";

/// @title FoodyVIPNFT — Soulbound VIP Membership Badge for FoodySwap
/// @notice Auto-minted when a user reaches VIP tier ($1000+ cumulative spend).
///         Grants permanent 12% discount on all restaurant swaps.
///         Soulbound (non-transferable) to prevent gaming.
contract FoodyVIPNFT is ERC721, Owned {
    uint256 private _nextTokenId;

    /// @notice Track which addresses hold a VIP NFT
    mapping(address => bool) public hasVIP;

    constructor() ERC721("Foody VIP", "FVIP") Owned(msg.sender) {}

    /// @notice Mint a VIP NFT to user. Only callable by owner (FoodySwapHook).
    /// @param to Recipient address
    /// @return tokenId The minted token ID
    function mintVIP(address to) external onlyOwner returns (uint256 tokenId) {
        require(!hasVIP[to], "Already VIP");
        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        hasVIP[to] = true;
    }

    /// @notice Returns metadata URI for a token
    function tokenURI(uint256 id) public pure override returns (string memory) {
        return string(abi.encodePacked("https://foodyepay.com/api/vip/", _toString(id)));
    }

    /// @dev Override transfer to make it soulbound (non-transferable)
    function transferFrom(address, address, uint256) public pure override {
        revert("Soulbound: non-transferable");
    }

    /// @dev Simple uint to string helper
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
