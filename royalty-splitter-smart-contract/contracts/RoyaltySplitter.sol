// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title Advanced Multi-Track Royalty Splitter
/// @notice Register tracks, set per-track splits, deposit royalties, and distribute via pull pattern.
/// @dev Percentages are stored as basis points (bps). 10000 = 100.00%
contract RoyaltySplitter is Ownable, ReentrancyGuard {
    struct Track {
        address owner;
        string nftId;
        bool exists;
    }

    // trackId => Track
    mapping(uint256 => Track) public tracks;

    // trackId => list of recipients
    mapping(uint256 => address[]) private trackRecipients;

    // trackId => recipient => percentage (bps)
    mapping(uint256 => mapping(address => uint16)) public splits;

    // pending withdrawals per address (in wei)
    mapping(address => uint256) public pendingWithdrawals;

    // events for ETL / indexer
    event TrackRegistered(uint256 indexed trackId, address indexed owner, string nftId);
    event SplitUpdated(uint256 indexed trackId, address[] recipients, uint16[] percentages);
    event RoyaltyDeposited(uint256 indexed trackId, address indexed payer, uint256 amount, bytes32 txHash);
    event RoyaltyDistributed(uint256 indexed trackId, uint256 totalAmount);
    event PayoutClaimed(address indexed recipient, uint256 amount);

    /// @notice Register a track with an owner and optional nftId
    function registerTrack(uint256 trackId, address ownerAddress, string memory nftId) external onlyOwner {
        require(!tracks[trackId].exists, "Track already exists");
        require(ownerAddress != address(0), "Owner address zero");
        tracks[trackId] = Track({owner: ownerAddress, nftId: nftId, exists: true});
        emit TrackRegistered(trackId, ownerAddress, nftId);
    }

    /// @notice Update split for a given track. Only track owner can call.
    /// @param trackId track identifier
    /// @param recipients list of recipient addresses
    /// @param percentages list of percentages in bps (sum must equal 10000)
    function setSplits(uint256 trackId, address[] calldata recipients, uint16[] calldata percentages) external {
        require(tracks[trackId].exists, "Track not found");
        require(tracks[trackId].owner == msg.sender, "Only track owner");
        require(recipients.length == percentages.length, "Array length mismatch");
        require(recipients.length > 0, "Empty recipients");

        uint256 sum = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            require(recipients[i] != address(0), "Recipient zero");
            sum += percentages[i];
        }
        require(sum == 10000, "Percentages must sum to 10000 (100%)");

        // clear previous recipients list (gas cost proportional to previous size)
        address[] storage prev = trackRecipients[trackId];
        for (uint256 i = 0; i < prev.length; i++) {
            delete splits[trackId][prev[i]];
        }

        // set new splits and recipients
        delete trackRecipients[trackId];
        for (uint256 i = 0; i < recipients.length; i++) {
            trackRecipients[trackId].push(recipients[i]);
            splits[trackId][recipients[i]] = percentages[i];
        }

        emit SplitUpdated(trackId, recipients, percentages);
    }

    /// @notice Deposit royalty for a track (payable). Emits RoyaltyDeposited for ETL.
    function depositRoyalty(uint256 trackId) external payable {
        require(tracks[trackId].exists, "Track not found");
        require(msg.value > 0, "No ETH sent");

        // txHash as pointer for ETL (not real chain hash) — include blockhash+tx.origin to help indexer
        bytes32 txHash = keccak256(abi.encodePacked(block.number, msg.sender, msg.value, block.timestamp));
        emit RoyaltyDeposited(trackId, msg.sender, msg.value, txHash);

        // Auto-distribute into pendingWithdrawals (safe, pull-based)
        _distributeToPending(trackId, msg.value);
    }

    /// @dev internal: compute shares and increment pendingWithdrawals
    function _distributeToPending(uint256 trackId, uint256 amount) internal {
        address[] storage recs = trackRecipients[trackId];
        require(recs.length > 0, "No recipients set");

        // avoid rounding loss by distributing integer-wise and sending remainder to owner
        uint256 distributed = 0;
        for (uint256 i = 0; i < recs.length; i++) {
            address r = recs[i];
            uint16 bps = splits[trackId][r];
            uint256 share = (amount * bps) / 10000;
            if (share > 0) {
                pendingWithdrawals[r] += share;
                distributed += share;
            }
        }

        uint256 remainder = amount - distributed;
        if (remainder > 0) {
            // send remainder to track owner pending balance
            address ownerAddr = tracks[trackId].owner;
            pendingWithdrawals[ownerAddr] += remainder;
        }

        emit RoyaltyDistributed(trackId, amount);
    }

    /// @notice Allow recipients to withdraw their pending balance (pull model)
    function claimPayout() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "No pending payout");
        pendingWithdrawals[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH transfer failed");
        emit PayoutClaimed(msg.sender, amount);
    }

    /// @notice View recipients for a track
    function getRecipients(uint256 trackId) external view returns (address[] memory) {
        return trackRecipients[trackId];
    }

    /// @notice Admin recovery: withdraw contract balance to owner (emergency)
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= address(this).balance, "Insufficient balance");
        (bool ok, ) = payable(owner()).call{value: amount}("");
        require(ok, "Transfer failed");
    }
}
