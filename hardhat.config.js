/**
 * Hardhat config for deploying to Arc Testnet (Circle).
 *
 * Secrets (private key) are read from a .env file — copy .env.example
 * to .env and fill in your values. NEVER commit your .env file.
 */
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

// Deployer wallet private key (with or without the 0x prefix, both work).
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

// Arc Testnet RPC (verified chain ID: 5042002).
// The public RPC has a strict rate limit (~1 req/s) — a dedicated
// Alchemy RPC (ARC_RPC_URL_ALCHEMY, see .env.example) is used first if
// set, otherwise this falls back to ARC_RPC_URL / the public RPC.
const ARC_RPC_URL =
  process.env.ARC_RPC_URL_ALCHEMY ||
  process.env.ARC_RPC_URL ||
  "https://rpc.testnet.arc.network";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    // Local Hardhat network (for tests) — nothing to configure.
    hardhat: {},

    // Circle's Arc Testnet.
    arcTestnet: {
      url: ARC_RPC_URL,
      chainId: 5042002,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
};
