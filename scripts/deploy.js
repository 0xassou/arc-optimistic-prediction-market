/**
 * Deployment script for OptimisticPredictionMarket on Arc Testnet.
 *
 * Usage:
 *   npx hardhat run scripts/deploy.js --network arcTestnet
 *
 * Prerequisites:
 *   1. A filled-in .env file (PRIVATE_KEY + USDC_ADDRESS).
 *   2. Testnet USDC on Arc to pay gas (on Arc, gas is paid in USDC —
 *      the network's native currency — not ETH).
 *
 * If USDC_ADDRESS isn't set, the script deploys a MockUSDC (test token)
 * first and uses that — handy for testing without the Circle faucet.
 */
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with wallet:", deployer.address);

  // On Arc, the native currency (which pays gas) is USDC (18 decimals
  // at the native level) — formatEther therefore converts correctly.
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Native balance (gas):", hre.ethers.formatEther(balance), "USDC\n");

  // ------------------------------------------------------------------
  // 1. Determine the USDC address
  // ------------------------------------------------------------------
  let usdcAddress = process.env.USDC_ADDRESS;

  if (!usdcAddress) {
    console.log("USDC_ADDRESS is not set in .env");
    console.log("-> Deploying a MockUSDC (test token)...");
    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const mockUsdc = await MockUSDC.deploy();
    await mockUsdc.waitForDeployment();
    usdcAddress = await mockUsdc.getAddress();
    console.log("MockUSDC deployed at:", usdcAddress);
    console.log("   (call faucet() on it to get 1000 test USDC)\n");
  } else {
    console.log("Using USDC at:", usdcAddress, "\n");
  }

  // ------------------------------------------------------------------
  // 2. Deploy OptimisticPredictionMarket
  // ------------------------------------------------------------------
  // Fee treasury: TREASURY_ADDRESS from .env, defaults to the deployer.
  const treasuryAddress = process.env.TREASURY_ADDRESS || deployer.address;
  console.log("-> Deploying OptimisticPredictionMarket...");
  console.log("   Fee treasury:", treasuryAddress);
  const OptimisticPredictionMarket = await hre.ethers.getContractFactory(
    "OptimisticPredictionMarket"
  );
  const market = await OptimisticPredictionMarket.deploy(usdcAddress, treasuryAddress);
  await market.waitForDeployment();
  const marketAddress = await market.getAddress();

  console.log("OptimisticPredictionMarket deployed at:", marketAddress);

  // ------------------------------------------------------------------
  // 3. Summary
  // ------------------------------------------------------------------
  console.log("\n========================================================");
  console.log("Deployment summary");
  console.log("========================================================");
  console.log(`MARKET_ADDRESS=${marketAddress}`);
  console.log(`USDC_ADDRESS=${usdcAddress}`);
  console.log(`TREASURY_ADDRESS=${treasuryAddress}`);
  console.log("========================================================\n");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
