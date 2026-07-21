// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ============================================================================
 *  MOCK USDC — test-only token
 * ============================================================================
 *
 *  On Arc Testnet, prefer using Circle's REAL testnet USDC (via the
 *  official faucet: https://faucet.circle.com).
 *
 *  This contract is a fallback: if you can't get testnet USDC, deploy
 *  this mock and mint yourself as many tokens as you need via faucet().
 *
 *  Like real USDC, it uses 6 decimals (1 USDC = 1_000_000 units).
 * ============================================================================
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    /// USDC uses 6 decimals (not 18 like most ERC-20 tokens).
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// Anyone can mint themselves 1,000 test USDC per call.
    function faucet() external {
        _mint(msg.sender, 1_000 * 10 ** 6);
    }

    /// Mints an arbitrary amount to an address (tests only).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
