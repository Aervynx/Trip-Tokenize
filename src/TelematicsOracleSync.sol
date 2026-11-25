// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TelematicsOracleSync
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice On-chain IoT telematics bridge tracking mileage, vehicle health index, and dynamic reserve ratios.
 */
contract TelematicsOracleSync {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant ORACLE_FEEDER_ROLE = keccak256("ORACLE_FEEDER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

    struct VehicleTelemetry {
        uint256 odometerKm;
        uint256 engineHours;
        uint256 fuelEfficiencyBps; // e.g., 1250 = 12.50 L/100km
        uint8 healthIndex;         // 0 to 100
        uint256 lastUpdated;
        bytes32 telemetryDataHash;
        bool maintenanceRequired;
        bool initialized;
    }

    uint256 public baseReserveBps = 1000;      // 10% when health >= 80
    uint256 public elevatedReserveBps = 1500;  // 15% when 60 <= health < 80
    uint256 public criticalReserveBps = 2500;  // 25% when health < 60
    uint8 public alertHealthThreshold = 60;

    bytes32[] public trackedAssets;
    mapping(bytes32 => VehicleTelemetry) public telemetryByAsset;
    mapping(bytes32 => mapping(address => bool)) private _roles;

    event TelemetrySynced(
        bytes32 indexed assetId,
        uint256 odometerKm,
        uint256 engineHours,
        uint8 healthIndex,
        bytes32 telemetryDataHash
    );
    event MaintenanceAlertTriggered(bytes32 indexed assetId, uint8 healthIndex, uint256 odometerKm);
    event MaintenanceAlertCleared(bytes32 indexed assetId, uint8 newHealthIndex);
    event ReservePolicyUpdated(uint256 baseBps, uint256 elevatedBps, uint256 criticalBps);
    event RoleGranted(bytes32 indexed role, address indexed account);
    event RoleRevoked(bytes32 indexed role, address indexed account);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: unauthorized");
        _;
    }

    constructor(address admin) {
        require(admin != address(0), "Invalid admin");
        _roles[DEFAULT_ADMIN_ROLE][admin] = true;
        _roles[ORACLE_FEEDER_ROLE][admin] = true;
        emit RoleGranted(DEFAULT_ADMIN_ROLE, admin);
        emit RoleGranted(ORACLE_FEEDER_ROLE, admin);
    }

    function syncTelemetry(
        bytes32 assetId,
        uint256 odometerKm,
        uint256 engineHours,
        uint256 fuelEfficiencyBps,
        uint8 healthIndex,
        bytes32 telemetryDataHash
    ) external onlyRole(ORACLE_FEEDER_ROLE) {
        require(assetId != bytes32(0), "Invalid assetId");
        require(healthIndex <= 100, "Health index must be <= 100");
        require(telemetryDataHash != bytes32(0), "Invalid telemetry hash");

        VehicleTelemetry storage data = telemetryByAsset[assetId];

        if (!data.initialized) {
            data.initialized = true;
            trackedAssets.push(assetId);
        } else {
            require(odometerKm >= data.odometerKm, "Odometer rollback detected");
            require(engineHours >= data.engineHours, "Engine hours rollback detected");
        }

        bool wasAlert = data.maintenanceRequired;
        bool isAlert = healthIndex < alertHealthThreshold;

        data.odometerKm = odometerKm;
        data.engineHours = engineHours;
        data.fuelEfficiencyBps = fuelEfficiencyBps;
        data.healthIndex = healthIndex;
        data.lastUpdated = block.timestamp;
        data.telemetryDataHash = telemetryDataHash;
        data.maintenanceRequired = isAlert;

        emit TelemetrySynced(assetId, odometerKm, engineHours, healthIndex, telemetryDataHash);

        if (isAlert) {
            emit MaintenanceAlertTriggered(assetId, healthIndex, odometerKm);
        } else if (wasAlert && !isAlert) {
            emit MaintenanceAlertCleared(assetId, healthIndex);
        }
    }

    function getRecommendedReserveBps(bytes32 assetId) public view returns (uint256) {
        VehicleTelemetry storage data = telemetryByAsset[assetId];
        require(data.initialized, "Asset telemetry not initialized");

        if (data.healthIndex >= 80) {
            return baseReserveBps;
        }
        if (data.healthIndex >= 60) {
            return elevatedReserveBps;
        }
        return criticalReserveBps;
    }

    function getFleetAverageHealth() external view returns (uint256) {
        uint256 count = trackedAssets.length;
        if (count == 0) {
            return 100;
        }
        uint256 totalHealth;
        for (uint256 i = 0; i < count; i++) {
            totalHealth += telemetryByAsset[trackedAssets[i]].healthIndex;
        }
        return totalHealth / count;
    }

    function trackedAssetsCount() external view returns (uint256) {
        return trackedAssets.length;
    }

    function setReservePolicy(
        uint256 _baseBps,
        uint256 _elevatedBps,
        uint256 _criticalBps,
        uint8 _alertThreshold
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_baseBps <= _elevatedBps && _elevatedBps <= _criticalBps, "Invalid ascending order");
        require(_criticalBps <= 5000, "Reserve cap exceeded");
        require(_alertThreshold <= 90, "Invalid alert threshold");

        baseReserveBps = _baseBps;
        elevatedReserveBps = _elevatedBps;
        criticalReserveBps = _criticalBps;
        alertHealthThreshold = _alertThreshold;

        emit ReservePolicyUpdated(_baseBps, _elevatedBps, _criticalBps);
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Invalid account");
        _roles[role][account] = true;
        emit RoleGranted(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _roles[role][account] = false;
        emit RoleRevoked(role, account);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}
