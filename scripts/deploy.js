const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Deploying Advanced Governance Protocol...\n");

  // Get deployer account
  const [deployer] = await ethers.getSigners();
  console.log("📝 Deploying contracts with account:", deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(await deployer.provider.getBalance(deployer.address)), "ETH\n");

  // Deploy GovernanceToken
  console.log("🎯 Step 1: Deploying GovernanceToken...");
  const GovernanceToken = await ethers.getContractFactory("GovernanceToken");
  const governanceToken = await GovernanceToken.deploy(
    "Advanced Governance Token",
    "AGOV",
    deployer.address
  );
  await governanceToken.waitForDeployment();
  console.log("✅ GovernanceToken deployed to:", governanceToken.target);
  console.log("📊 Total supply:", ethers.formatEther(await governanceToken.totalSupply()), "AGOV\n");

  // Deploy AdvancedTimelockController
  console.log("⏰ Step 2: Deploying AdvancedTimelockController...");
  const minDelay = 2 * 24 * 60 * 60; // 2 days
  const TimelockController = await ethers.getContractFactory("AdvancedTimelockController");
  const timelockController = await TimelockController.deploy(
    deployer.address, // admin
    deployer.address, // proposer
    deployer.address, // executor
    deployer.address, // emergency executor
    minDelay
  );
  await timelockController.waitForDeployment();
  console.log("✅ TimelockController deployed to:", timelockController.target);
  console.log("⏱️ Minimum delay:", minDelay, "seconds\n");

  // Deploy GovernanceCore
  console.log("🏛️ Step 3: Deploying GovernanceCore...");
  const GovernanceCore = await ethers.getContractFactory("GovernanceCore");
  const governanceCore = await GovernanceCore.deploy(
    governanceToken,
    timelockController,
    deployer.address // emergency executor
  );
  await governanceCore.waitForDeployment();
  console.log("✅ GovernanceCore deployed to:", governanceCore.target);

  // Deploy VotingAnalytics
  console.log("📊 Step 4: Deploying VotingAnalytics...");
  const VotingAnalytics = await ethers.getContractFactory("VotingAnalytics");
  const votingAnalytics = await VotingAnalytics.deploy(
    governanceToken,
    governanceCore,
    deployer.address
  );
  await votingAnalytics.waitForDeployment();
  console.log("✅ VotingAnalytics deployed to:", votingAnalytics.target, "\n");

  // Setup governance roles
  console.log("🔧 Step 5: Setting up governance roles...");
  
  // Transfer timelock ownership to governance core
  console.log("📝 Transferring timelock ownership to GovernanceCore...");
  await timelockController.connect(deployer).grantRole(
    await timelockController.PROPOSER_ROLE(),
    governanceCore.target
  );
  await timelockController.connect(deployer).grantRole(
    await timelockController.EXECUTOR_ROLE(),
    governanceCore.target
  );
  await timelockController.connect(deployer).grantRole(
    await timelockController.CANCELLER_ROLE(),
    governanceCore.target
  );
  console.log("✅ Governance roles configured\n");

  // Setup token delegation for initial governance
  console.log("🎯 Step 6: Setting up initial governance...");
  
  // Self-delegate for voting power
  await governanceToken.connect(deployer).delegate(deployer.address);
  console.log("✅ Self-delegation completed");
  
  // Upgrade some accounts to different tiers for testing
  const [, addr1, addr2, addr3] = await ethers.getSigners();
  
  // Transfer tokens to test accounts
  const transferAmount = ethers.parseEther("10000");
  await governanceToken.transfer(addr1.address, transferAmount);
  await governanceToken.transfer(addr2.address, transferAmount);
  await governanceToken.transfer(addr3.address, transferAmount);
  
  // Upgrade tiers
  await governanceToken.upgradeTier(addr1.address, 2); // Silver
  await governanceToken.upgradeTier(addr2.address, 3); // Gold
  await governanceToken.upgradeTier(addr3.address, 4); // Platinum
  
  console.log("✅ Test accounts funded and tier-upgraded\n");

  // Verify setup
  console.log("🔍 Step 7: Verifying deployment...");
  
  const votingPower = await governanceToken.getVotes(deployer.address);
  const quorum = await governanceCore.quorum(await ethers.provider.getBlockNumber());
  const proposalThreshold = await governanceCore.proposalThreshold();
  
  console.log("📊 Deployment Summary:");
  console.log("├── GovernanceToken:", governanceToken.target);
  console.log("├── TimelockController:", timelockController.target);
  console.log("├── GovernanceCore:", governanceCore.target);
  console.log("├── VotingAnalytics:", votingAnalytics.target);
  console.log("├── Deployer voting power:", ethers.formatEther(votingPower), "AGOV");
  console.log("├── Quorum requirement:", ethers.formatEther(quorum), "AGOV");
  console.log("└── Proposal threshold:", ethers.formatEther(proposalThreshold), "AGOV\n");

  // Save deployment addresses
  const deploymentInfo = {
    network: (await ethers.provider.getNetwork()).name,
    chainId: (await ethers.provider.getNetwork()).chainId,
    deployer: deployer.address,
    contracts: {
      GovernanceToken: governanceToken.target,
      TimelockController: timelockController.target,
      GovernanceCore: governanceCore.target,
      VotingAnalytics: votingAnalytics.target,
    },
    deployedAt: new Date().toISOString(),
  };

  console.log("💾 Deployment Info:");
  console.log(JSON.stringify(deploymentInfo, null, 2));

  // Write deployment info to file
  const fs = require("fs");
  const deploymentPath = `./deployments/${deploymentInfo.network}-${deploymentInfo.chainId}.json`;
  
  // Ensure deployments directory exists
  if (!fs.existsSync("./deployments")) {
    fs.mkdirSync("./deployments");
  }
  
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log("📁 Deployment info saved to:", deploymentPath);

  console.log("\n🎉 Advanced Governance Protocol deployed successfully!");
  console.log("🚀 Ready for enterprise-grade decentralized governance!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment failed:", error);
    process.exit(1);
  });
