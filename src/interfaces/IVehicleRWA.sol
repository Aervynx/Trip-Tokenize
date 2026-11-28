// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVehicleRWA Interfaces
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Shared interfaces connecting all modules of the Commercial Vehicle Fleets RWA protocol.
 */

interface IVehicleProfitPoolHook {
    function updateEarnings(address account) external;
}

interface IVehicleProfitPool {
    function finalizePeriod(
        bytes32 periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve
    ) external;
}

interface IVehicleRegistry {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function isWhitelisted(address account) external view returns (bool);
}

interface ITelematicsOracleSync {
    function getRecommendedReserveBps(bytes32 assetId) external view returns (uint256);
    function getFleetAverageHealth() external view returns (uint256);
}

interface IAutomatedTaxAndAuditLedger {
    struct EntryInput {
        bytes32 periodId;
        bytes32 assetId;
        uint256 grossRevenue;
        uint256 deductibleOpex;
        uint256 depreciationAmount;
        uint256 reserveAllocation;
        uint256 investorDistribution;
        uint256 operatorDistribution;
        bytes32 auditDocHash;
    }

    function recordPeriodEntry(EntryInput calldata input) external returns (uint256 entryId);
}
