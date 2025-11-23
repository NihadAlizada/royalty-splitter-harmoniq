const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with:", deployer.address);

  const RoyaltySplitter = await hre.ethers.getContractFactory("RoyaltySplitter");
  const royalty = await RoyaltySplitter.deploy();
  await royalty.deployed();

  console.log("RoyaltySplitter deployed to:", royalty.address);

  // Save artifacts for frontend / indexer
  const fs = require("fs");
  const path = require("path");
  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) fs.mkdirSync(deploymentsDir);
  fs.writeFileSync(path.join(deploymentsDir, "RoyaltySplitter-address.txt"), royalty.address);
  fs.writeFileSync(path.join(deploymentsDir, "RoyaltySplitter-ABI.json"), JSON.stringify(require("../artifacts/contracts/RoyaltySplitter.sol/RoyaltySplitter.json").abi, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
