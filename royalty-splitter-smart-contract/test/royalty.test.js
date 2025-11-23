const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("RoyaltySplitter", function () {
  let RoyaltySplitter;
  let royalty;
  let owner, alice, bob, carol;

  beforeEach(async function () {
    [owner, alice, bob, carol] = await ethers.getSigners();
    RoyaltySplitter = await ethers.getContractFactory("RoyaltySplitter");
    royalty = await RoyaltySplitter.deploy();
    await royalty.deployed();

    // create a track (owner is deployer)
    await royalty.registerTrack(1, alice.address, "NFT-1");
    // set splits: alice 70%, bob 30%
    await royalty.connect(alice).setSplits(1, [alice.address, bob.address], [7000, 3000]);
  });

  it("registers track correctly", async function () {
    const t = await royalty.tracks(1);
    expect(t.exists).to.equal(true);
    expect(t.owner).to.equal(alice.address);
  });

  it("setSplits fails when not owner", async function () {
    await expect(royalty.connect(bob).setSplits(1, [alice.address], [10000])).to.be.revertedWith("Only track owner");
  });

  it("setSplits fails when percentages do not sum", async function () {
    await expect(royalty.connect(alice).setSplits(1, [alice.address], [9000])).to.be.revertedWith("Percentages must sum to 10000 (100%)");
  });

  it("deposit and increases pending withdrawals", async function () {
    // send 1 ETH to depositRoyalty
    await royalty.connect(bob).depositRoyalty(1, { value: ethers.utils.parseEther("1.0") });
    // check pending balances
    const pendingAlice = await royalty.pendingWithdrawals(alice.address);
    const pendingBob = await royalty.pendingWithdrawals(bob.address);
    // alice should get 0.7 ETH, bob 0.3 ETH (in wei)
    expect(pendingAlice).to.equal(ethers.utils.parseEther("0.7"));
    expect(pendingBob).to.equal(ethers.utils.parseEther("0.3"));
  });

  it("claimPayout withdraws funds", async function () {
    await royalty.connect(bob).depositRoyalty(1, { value: ethers.utils.parseEther("2.0") });
    const before = await ethers.provider.getBalance(alice.address);
    // alice claims
    const tx = await royalty.connect(alice).claimPayout();
    const receipt = await tx.wait();
    const gas = receipt.gasUsed.mul(receipt.effectiveGasPrice);
    const after = await ethers.provider.getBalance(alice.address);
    expect(after).to.be.above(before.sub(gas)); // balance increased
  });

  it("distributes remainder to owner when rounding", async function () {
    // choose amounts that cause rounding remainder
    await royalty.connect(bob).depositRoyalty(1, { value: 1 }); // 1 wei
    // since shares computed as integer, distributed likely 0 for both, remainder should go to owner (alice)
    const pendingAlice = await royalty.pendingWithdrawals(alice.address);
    expect(pendingAlice.gte(1)).to.be.true;
  });

  it("does not allow register same track twice", async function () {
    await expect(royalty.registerTrack(1, alice.address, "NFT-1")).to.be.revertedWith("Track already exists");
  });

  it("tracking recipients is correct", async function () {
    const recs = await royalty.getRecipients(1);
    expect(recs.length).to.equal(2);
    expect(recs[0]).to.equal(alice.address);
    expect(recs[1]).to.equal(bob.address);
  });

  it("claimPayout fails when no funds", async function () {
    await expect(royalty.connect(carol).claimPayout()).to.be.revertedWith("No pending payout");
  });

  it("emergencyWithdraw works for owner only", async function () {
    // deposit to contract
    await royalty.connect(bob).depositRoyalty(1, { value: ethers.utils.parseEther("1.0") });
    // owner withdraws
    const initialContract = await ethers.provider.getBalance(royalty.address);
    expect(initialContract).to.equal(ethers.utils.parseEther("1.0"));
    // owner (deployer) calls emergencyWithdraw
    await royalty.connect(owner).emergencyWithdraw(ethers.utils.parseEther("1.0"));
    const after = await ethers.provider.getBalance(royalty.address);
    expect(after).to.equal(0);
  });

  // Additional edge cases
  it("setSplits rejects zero recipient", async function () {
    await expect(royalty.connect(alice).setSplits(1, [ethers.constants.AddressZero], [10000])).to.be.revertedWith("Recipient zero");
  });

  it("deposit fails when track not found", async function () {
    await expect(royalty.connect(bob).depositRoyalty(999, { value: 1 })).to.be.revertedWith("Track not found");
  });
});
