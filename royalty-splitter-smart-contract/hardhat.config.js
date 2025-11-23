require("@nomicfoundation/hardhat-toolbox");

const SEPOLIA_RPC = process.env.SEPOLIA_RPC || "";
const PRIVATE_KEY = process.env.DEPLOYER_KEY || "";

module.exports = {
  solidity: "0.8.19",
  networks: {
    hardhat: {},
    sepolia: {
      url: SEPOLIA_RPC,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : []
    }
  },
  mocha: {
    timeout: 200000
  }
};
