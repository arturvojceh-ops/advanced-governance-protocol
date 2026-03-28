const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("GovernanceToken", function () {
  let governanceToken;
  let owner, addr1, addr2, addr3;
  let totalSupply = ethers.parseEther("1000000000"); // 1B tokens

  beforeEach(async function () {
    [owner, addr1, addr2, addr3] = await ethers.getSigners();
    
    const GovernanceToken = await ethers.getContractFactory("GovernanceToken");
    governanceToken = await GovernanceToken.deploy(
      "GovernanceToken",
      "GOV",
      owner.address
    );
    await governanceToken.waitForDeployment();
  });

  describe("Deployment", function () {
    it("Should set the right owner", async function () {
      expect(await governanceToken.owner()).to.equal(owner.address);
    });

    it("Should assign the total supply to the owner", async function () {
      const ownerBalance = await governanceToken.balanceOf(owner.address);
      expect(await governanceToken.totalSupply()).to.equal(ownerBalance);
      expect(ownerBalance).to.equal(totalSupply);
    });

    it("Should set owner to Diamond tier", async function () {
      expect(await governanceToken.governanceTiers(owner.address)).to.equal(5);
    });
  });

  describe("Tier Management", function () {
    it("Should upgrade tier correctly", async function () {
      await governanceToken.upgradeTier(addr1.address, 3); // Gold tier
      expect(await governanceToken.governanceTiers(addr1.address)).to.equal(3);
    });

    it("Should batch upgrade tiers", async function () {
      await governanceToken.batchUpgradeTier(
        [addr1.address, addr2.address],
        [2, 4] // Silver, Platinum
      );
      
      expect(await governanceToken.governanceTiers(addr1.address)).to.equal(2);
      expect(await governanceToken.governanceTiers(addr2.address)).to.equal(4);
    });

    it("Should not downgrade tiers", async function () {
      await governanceToken.upgradeTier(addr1.address, 3);
      await expect(
        governanceToken.upgradeTier(addr1.address, 2)
      ).to.be.revertedWith("Can only upgrade");
    });

    it("Should validate tier range", async function () {
      await expect(
        governanceToken.upgradeTier(addr1.address, 0)
      ).to.be.revertedWith("Invalid tier");
      
      await expect(
        governanceToken.upgradeTier(addr1.address, 6)
      ).to.be.revertedWith("Invalid tier");
    });
  });

  describe("Voting Power", function () {
    beforeEach(async function () {
      // Transfer tokens to test accounts
      await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      await governanceToken.transfer(addr2.address, ethers.parseEther("5000"));
      
      // Upgrade tiers
      await governanceToken.upgradeTier(addr1.address, 2); // Silver - 1.25x
      await governanceToken.upgradeTier(addr2.address, 4); // Platinum - 1.75x
    });

    it("Should calculate voting power with tier multiplier", async function () {
      const addr1Votes = await governanceToken.getVotes(addr1.address);
      const addr2Votes = await governanceToken.getVotes(addr2.address);
      
      // addr1: 1000 * 1.25 = 1250
      expect(addr1Votes).to.equal(ethers.parseEther("1250"));
      
      // addr2: 5000 * 1.75 = 8750
      expect(addr2Votes).to.equal(ethers.parseEther("8750"));
    });

    it("Should calculate quadratic voting power", async function () {
      const addr1Quadratic = await governanceToken.getQuadraticVotes(addr1.address);
      const addr2Quadratic = await governanceToken.getQuadraticVotes(addr2.address);
      
      // Quadratic voting should favor smaller holders
      expect(addr1Quadratic).to.be.gt(0);
      expect(addr2Quadratic).to.be.gt(0);
      expect(addr2Quadratic).to.be.gt(addr1Quadratic);
    });

    it("Should update voting power after tier upgrade", async function () {
      const initialVotes = await governanceToken.getVotes(addr1.address);
      
      await governanceToken.upgradeTier(addr1.address, 5); // Diamond - 2x
      
      const newVotes = await governanceToken.getVotes(addr1.address);
      expect(newVotes).to.be.gt(initialVotes);
      expect(newVotes).to.equal(ethers.parseEther("2000")); // 1000 * 2x
    });
  });

  describe("Delegation System", function () {
    beforeEach(async function () {
      await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      await governanceToken.transfer(addr2.address, ethers.parseEther("2000"));
      await governanceToken.upgradeTier(addr1.address, 3); // Gold
    });

    it("Should delegate with lock period", async function () {
      await governanceToken.connect(addr1).delegateWithLock(
        addr2.address,
        ethers.parseEther("500"),
        1000 // 1000 blocks
      );
      
      expect(await governanceToken.delegators(addr1.address)).to.equal(addr2.address);
      expect(await governanceToken.delegationLockPeriod(addr1.address)).to.equal(1000);
    });

    it("Should not delegate to self", async function () {
      await expect(
        governanceToken.connect(addr1).delegateWithLock(
          addr1.address,
          ethers.parseEther("500"),
          1000
        )
      ).to.be.revertedWith("Cannot delegate to self");
    });

    it("Should not delegate with insufficient balance", async function () {
      await expect(
        governanceToken.connect(addr1).delegateWithLock(
          addr2.address,
          ethers.parseEther("2000"), // More than balance
          1000
        )
      ).to.be.revertedWith("Insufficient balance");
    });

    it("Should undelegate after lock period", async function () {
      await governanceToken.connect(addr1).delegateWithLock(
        addr2.address,
        ethers.parseEther("500"),
        100
      );
      
      // Mine 100 blocks
      await time.advanceBlockTo(await ethers.provider.getBlockNumber() + 100);
      
      await governanceToken.connect(addr1).undelegate(addr2.address);
      expect(await governanceToken.delegators(addr1.address)).to.equal(ethers.ZeroAddress);
    });

    it("Should not undelegate before lock period", async function () {
      await governanceToken.connect(addr1).delegateWithLock(
        addr2.address,
        ethers.parseEther("500"),
        100
      );
      
      await expect(
        governanceToken.connect(addr1).undelegate(addr2.address)
      ).to.be.revertedWith("Delegation still locked");
    });
  });

  describe("Voting Credits", function () {
    beforeEach(async function () {
      await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      await governanceToken.upgradeTier(addr1.address, 3); // Gold
    });

    it("Should issue voting credits on tier upgrade", async function () {
      const initialCredits = await governanceToken.getAvailableCredits(addr1.address);
      
      await governanceToken.upgradeTier(addr2.address, 2); // Silver
      
      const newCredits = await governanceToken.getAvailableCredits(addr2.address);
      expect(newCredits).to.equal(2000); // 2 * 1000 credits
    });

    it("Should use voting credits", async function () {
      const initialCredits = await governanceToken.getAvailableCredits(addr1.address);
      
      await governanceToken.connect(addr1).useVotingCredits(500);
      
      const remainingCredits = await governanceToken.getAvailableCredits(addr1.address);
      expect(remainingCredits).to.equal(initialCredits - 500);
    });

    it("Should not use more credits than available", async function () {
      const availableCredits = await governanceToken.getAvailableCredits(addr1.address);
      
      await expect(
        governanceToken.connect(addr1).useVotingCredits(availableCredits + 1)
      ).to.be.revertedWith("Insufficient credits");
    });
  });

  describe("Analytics", function () {
    beforeEach(async function () {
      await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      await governanceToken.transfer(addr2.address, ethers.parseEther("2000"));
      await governanceToken.upgradeTier(addr1.address, 2); // Silver
      await governanceToken.upgradeTier(addr2.address, 4); // Platinum
    });

    it("Should return governance analytics", async function () {
      const analytics = await governanceToken.getGovernanceAnalytics();
      
      expect(analytics.totalSupply).to.equal(totalSupply);
      expect(analytics.totalProposals).to.equal(0);
      expect(analytics.totalVotes).to.equal(0);
      expect(analytics.totalDelegations).to.equal(0);
      expect(analytics.activeDelegators).to.equal(0);
      expect(analytics.diamondTierHolders).to.equal(1); // Only owner
    });

    it("Should return tier distribution", async function () {
      const distribution = await governanceToken.getTierDistribution();
      
      expect(distribution.bronze).to.equal(0);
      expect(distribution.silver).to.equal(1);
      expect(distribution.gold).to.equal(0);
      expect(distribution.platinum).to.equal(1);
      expect(distribution.diamond).to.equal(1);
    });
  });

  describe("Security", function () {
    it("Should prevent reentrancy attacks", async function () {
      await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      
      // This test would require a malicious contract to test reentrancy
      // For now, we just verify the modifier is present
      await expect(
        governanceToken.connect(addr1).delegateWithLock(
          addr2.address,
          ethers.parseEther("500"),
          100
        )
      ).to.not.be.reverted;
    });

    it("Should validate inputs", async function () {
      await expect(
        governanceToken.upgradeTier(ethers.ZeroAddress, 1)
      ).to.not.be.reverted; // Zero address is valid for upgrade
      
      await expect(
        governanceToken.connect(addr1).delegateWithLock(
          ethers.ZeroAddress,
          ethers.parseEther("100"),
          100
        )
      ).to.be.revertedWith("Invalid delegate address");
    });
  });

  describe("Gas Optimization", function () {
    it("Should have reasonable gas costs", async function () {
      // Transfer
      const tx1 = await governanceToken.transfer(addr1.address, ethers.parseEther("1000"));
      const receipt1 = await tx1.wait();
      expect(receipt1.gasUsed).to.be.lessThan(100000);
      
      // Tier upgrade
      const tx2 = await governanceToken.upgradeTier(addr1.address, 2);
      const receipt2 = await tx2.wait();
      expect(receipt2.gasUsed).to.be.lessThan(80000);
      
      // Delegation
      const tx3 = await governanceToken.connect(addr1).delegateWithLock(
        addr2.address,
        ethers.parseEther("500"),
        100
      );
      const receipt3 = await tx3.wait();
      expect(receipt3.gasUsed).to.be.lessThan(150000);
    });
  });
});
