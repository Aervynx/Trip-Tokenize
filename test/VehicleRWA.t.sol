// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/**
 * @title VehicleRWARegistry
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Manages commercial vehicle fleet RWA tokenization, SPV structures, and compliance whitelisting on DotOne Chain 505.
 */
contract VehicleRWARegistry is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable
{
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    struct VehicleAsset {
        bytes32 assetId;
        address spvEntity;
        uint256 totalUnits;
        bool registered;
        bool active;
    }

    mapping(bytes32 => VehicleAsset) public vehicles;
    mapping(address => bool) public isWhitelisted;

    event VehicleRegistered(bytes32 indexed assetId, address indexed spvEntity, uint256 totalUnits);
    event VehicleStatusUpdated(bytes32 indexed assetId, bool active);
    event WhitelistUpdated(address indexed account, bool status);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory name_,
        string memory symbol_,
        address admin
    ) public initializer {
        require(admin != address(0), "Invalid admin");

        __ERC20_init(name_, symbol_);
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function registerVehicle(
        bytes32 assetId,
        address spvEntity,
        uint256 totalUnits
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        require(assetId != bytes32(0), "Invalid assetId");
        require(!vehicles[assetId].registered, "Already registered");
        require(spvEntity != address(0), "Invalid SPV");
        require(totalUnits > 0, "Invalid units");

        vehicles[assetId] = VehicleAsset({
            assetId: assetId,
            spvEntity: spvEntity,
            totalUnits: totalUnits,
            registered: true,
            active: true
        });

        _mint(spvEntity, totalUnits);

        emit VehicleRegistered(assetId, spvEntity, totalUnits);
    }

    function setVehicleActive(bytes32 assetId, bool active) external onlyRole(OPERATOR_ROLE) {
        require(vehicles[assetId].registered, "Not registered");
        vehicles[assetId].active = active;

        emit VehicleStatusUpdated(assetId, active);
    }

    function setWhitelist(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
        require(account != address(0), "Invalid account");
        isWhitelisted[account] = status;

        emit WhitelistUpdated(account, status);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override whenNotPaused {
        if (from != address(0) && to != address(0)) {
            require(isWhitelisted[from] && isWhitelisted[to], "Not whitelisted");
        }
        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
}
