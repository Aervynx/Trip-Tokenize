// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AutomatedTaxAndAuditLedger
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Immutable on-chain tax, depreciation, and regulatory audit ledger for SPV commercial vehicle fleets.
 */
contract AutomatedTaxAndAuditLedger {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant ACCOUNTANT_ROLE = keccak256("ACCOUNTANT_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

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

    struct LedgerEntry {
        uint256 entryId;
        bytes32 periodId;
        bytes32 assetId;
        uint256 grossRevenue;
        uint256 deductibleOpex;
        uint256 depreciationAmount;
        uint256 reserveAllocation;
        uint256 investorDistribution;
        uint256 operatorDistribution;
        uint256 taxableIncome;
        uint256 estimatedTax;
        bytes32 auditDocHash;
        uint256 recordedAt;
        address recordedBy;
    }

    struct AuditAdjustment {
        uint256 adjustmentId;
        uint256 originalEntryId;
        int256 taxableIncomeDelta;
        int256 taxDelta;
        bytes32 justificationHash;
        uint256 recordedAt;
        address recordedBy;
    }

    uint256 public taxRateBps;
    uint256 public nextEntryId;
    uint256 public nextAdjustmentId;

    uint256 public totalGrossRevenue;
    uint256 public totalDeductibleOpex;
    uint256 public totalDepreciation;
    uint256 public totalTaxableIncome;
    uint256 public totalEstimatedTax;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(uint256 => LedgerEntry) private _entries;
    mapping(uint256 => AuditAdjustment) private _adjustments;
    mapping(bytes32 => uint256) public entryIdByPeriodAndAsset;
    mapping(bytes32 => uint256) public accumulatedDepreciationByAsset;

    event LedgerEntryRecorded(
        uint256 indexed entryId,
        bytes32 indexed periodId,
        bytes32 indexed assetId,
        uint256 taxableIncome,
        uint256 estimatedTax,
        bytes32 auditDocHash
    );
    event AuditAdjustmentRecorded(
        uint256 indexed adjustmentId,
        uint256 indexed originalEntryId,
        int256 taxableIncomeDelta,
        int256 taxDelta,
        bytes32 justificationHash
    );
    event TaxRateUpdated(uint256 oldRateBps, uint256 newRateBps);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: unauthorized");
        _;
    }

    constructor(address admin, uint256 _taxRateBps) {
        require(admin != address(0), "Invalid admin");
        require(_taxRateBps <= 5000, "Tax rate exceeds 50%");

        taxRateBps = _taxRateBps;
        _roles[DEFAULT_ADMIN_ROLE][admin] = true;
        _roles[ACCOUNTANT_ROLE][admin] = true;
    }

    function recordPeriodEntry(EntryInput calldata input)
        external
        onlyRole(ACCOUNTANT_ROLE)
        returns (uint256 entryId)
    {
        require(input.periodId != bytes32(0), "Invalid periodId");
        require(input.auditDocHash != bytes32(0), "Invalid audit doc hash");

        bytes32 compositeKey = keccak256(abi.encodePacked(input.periodId, input.assetId));
        require(entryIdByPeriodAndAsset[compositeKey] == 0, "Entry already exists for period and asset");

        entryId = ++nextEntryId;
        entryIdByPeriodAndAsset[compositeKey] = entryId;

        (uint256 taxable, uint256 estTax) = _calculateTax(
            input.grossRevenue,
            input.deductibleOpex,
            input.depreciationAmount
        );

        _storeEntry(entryId, input, taxable, estTax);
        _updateTotals(input, taxable, estTax);

        emit LedgerEntryRecorded(
            entryId,
            input.periodId,
            input.assetId,
            taxable,
            estTax,
            input.auditDocHash
        );
    }

    function recordAdjustment(
        uint256 originalEntryId,
        int256 taxableIncomeDelta,
        int256 taxDelta,
        bytes32 justificationHash
    ) external onlyRole(ACCOUNTANT_ROLE) returns (uint256 adjustmentId) {
        require(_entries[originalEntryId].entryId != 0, "Original entry does not exist");
        require(justificationHash != bytes32(0), "Invalid justification hash");

        adjustmentId = ++nextAdjustmentId;

        AuditAdjustment storage adj = _adjustments[adjustmentId];
        adj.adjustmentId = adjustmentId;
        adj.originalEntryId = originalEntryId;
        adj.taxableIncomeDelta = taxableIncomeDelta;
        adj.taxDelta = taxDelta;
        adj.justificationHash = justificationHash;
        adj.recordedAt = block.timestamp;
        adj.recordedBy = msg.sender;

        emit AuditAdjustmentRecorded(
            adjustmentId,
            originalEntryId,
            taxableIncomeDelta,
            taxDelta,
            justificationHash
        );
    }

    function getEntry(uint256 entryId) external view returns (LedgerEntry memory) {
        require(_entries[entryId].entryId != 0, "Entry does not exist");
        return _entries[entryId];
    }

    function getEntryByPeriodAndAsset(
        bytes32 periodId,
        bytes32 assetId
    ) external view returns (LedgerEntry memory) {
        uint256 entryId = entryIdByPeriodAndAsset[keccak256(abi.encodePacked(periodId, assetId))];
        require(entryId != 0, "Entry does not exist");
        return _entries[entryId];
    }

    function getAdjustment(uint256 adjustmentId) external view returns (AuditAdjustment memory) {
        require(_adjustments[adjustmentId].adjustmentId != 0, "Adjustment does not exist");
        return _adjustments[adjustmentId];
    }

    function setTaxRateBps(uint256 newRateBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newRateBps <= 5000, "Tax rate exceeds 50%");
        uint256 oldRate = taxRateBps;
        taxRateBps = newRateBps;
        emit TaxRateUpdated(oldRate, newRateBps);
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Invalid account");
        _roles[role][account] = true;
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function _calculateTax(
        uint256 grossRevenue,
        uint256 deductibleOpex,
        uint256 depreciationAmount
    ) internal view returns (uint256 taxable, uint256 estTax) {
        uint256 totalDeductions = deductibleOpex + depreciationAmount;
        taxable = grossRevenue > totalDeductions ? grossRevenue - totalDeductions : 0;
        estTax = (taxable * taxRateBps) / BPS_DENOMINATOR;
    }

    function _storeEntry(
        uint256 entryId,
        EntryInput calldata input,
        uint256 taxable,
        uint256 estTax
    ) internal {
        LedgerEntry storage entry = _entries[entryId];
        entry.entryId = entryId;
        entry.periodId = input.periodId;
        entry.assetId = input.assetId;
        entry.grossRevenue = input.grossRevenue;
        entry.deductibleOpex = input.deductibleOpex;
        entry.depreciationAmount = input.depreciationAmount;
        entry.reserveAllocation = input.reserveAllocation;
        entry.investorDistribution = input.investorDistribution;
        entry.operatorDistribution = input.operatorDistribution;
        entry.taxableIncome = taxable;
        entry.estimatedTax = estTax;
        entry.auditDocHash = input.auditDocHash;
        entry.recordedAt = block.timestamp;
        entry.recordedBy = msg.sender;
    }

    function _updateTotals(
        EntryInput calldata input,
        uint256 taxable,
        uint256 estTax
    ) internal {
        totalGrossRevenue += input.grossRevenue;
        totalDeductibleOpex += input.deductibleOpex;
        totalDepreciation += input.depreciationAmount;
        totalTaxableIncome += taxable;
        totalEstimatedTax += estTax;

        if (input.assetId != bytes32(0)) {
            accumulatedDepreciationByAsset[input.assetId] += input.depreciationAmount;
        }
    }
}
