const { ethers } = require("hardhat");

async function main() {
  console.log("Deploying FlipSki V2 Contract...");

  // Get the ContractFactory and Signers here.
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);
  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  // Base Mainnet VRF Configuration
  const VRF_COORDINATOR = "0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634"; // Base Mainnet VRF Coordinator
  const KEY_HASH = "0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70"; // Base Mainnet Key Hash
  const SUBSCRIPTION_ID = process.env.VRF_SUBSCRIPTION_ID || "1"; // Replace with your subscription ID
  
  // Contract configuration
  const INITIAL_FEE_WALLET = process.env.FEE_WALLET || deployer.address;
  const INITIAL_FEE_PERCENTAGE = 1000; // 5% in basis points
  const INITIAL_OWNER = process.env.INITIAL_OWNER || deployer.address;

  console.log("Deployment Configuration:");
  console.log("- VRF Coordinator:", VRF_COORDINATOR);
  console.log("- Key Hash:", KEY_HASH);
  console.log("- Subscription ID:", SUBSCRIPTION_ID);
  console.log("- Fee Wallet:", INITIAL_FEE_WALLET);
  console.log("- Fee Percentage:", INITIAL_FEE_PERCENTAGE, "basis points");
  console.log("- Initial Owner:", INITIAL_OWNER);

  // Deploy the contract
  const FlipSkiV2 = await ethers.getContractFactory("FlipSkiV2");
  const flipSkiV2 = await FlipSkiV2.deploy(
    INITIAL_FEE_WALLET,
    INITIAL_FEE_PERCENTAGE,
    VRF_COORDINATOR,
    SUBSCRIPTION_ID,
    KEY_HASH,
    INITIAL_OWNER
  );

  await flipSkiV2.waitForDeployment();
  const contractAddress = await flipSkiV2.getAddress();

  console.log("FlipSki V2 deployed to:", contractAddress);

  // Wait for a few block confirmations
  console.log("Waiting for block confirmations...");
  await flipSkiV2.deploymentTransaction().wait(5);

  console.log("Deployment completed!");
  console.log("\nNext steps:");
  console.log("1. Add the contract as a consumer to your VRF subscription");
  console.log("2. Fund the contract with ETH for house balance");
  console.log("3. Add additional ERC20 tokens using addToken() function");
  console.log("4. Update frontend configuration with new contract address");

  // Save deployment info
  const deploymentInfo = {
    contractAddress: contractAddress,
    network: hre.network.name,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    vrfCoordinator: VRF_COORDINATOR,
    keyHash: KEY_HASH,
    subscriptionId: SUBSCRIPTION_ID,
    feeWallet: INITIAL_FEE_WALLET,
    feePercentage: INITIAL_FEE_PERCENTAGE,
    initialOwner: INITIAL_OWNER
  };

  console.log("\nDeployment Info:");
  console.log(JSON.stringify(deploymentInfo, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

