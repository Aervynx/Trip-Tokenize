// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IProfitPoolRewardHook {
    function updateEarnings(address account) external;
}

/**
 * @title VehicleRWARegistry
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice UUPS upgradeable registry for commercial vehicle fleet RWA units with compliance whitelisting,
 *         ERC20Votes snapshot governance power, and automatic profit-pool reward checkpointing on transfer.
 */
contract VehicleRWARegistry is
    Initializable,
    ERC20Upgradeable,
    ERC20VotesUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
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

    IProfitPoolRewardHook public profitPool;
    bytes32[] public registeredAssetIds;

    mapping(bytes32 => VehicleAsset) public vehicles;
    mapping(address => bool) public isWhitelisted;

    event VehicleRegistered(bytes32 indexed assetId, address indexed spvEntity, uint256 totalUnits);
    event VehicleStatusUpdated(bytes32 indexed assetId, bool active);
    event WhitelistUpdated(address indexed account, bool status);
    event ProfitPoolUpdated(address indexed oldPool, address indexed newPool);

    error InvalidAddress();
    error InvalidAssetId();
    error InvalidUnits();
    error VehicleAlreadyRegistered(bytes32 assetId);
    error VehicleNotRegistered(bytes32 assetId);
    error AccountNotWhitelisted(address account);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the registry token, EIP-712 voting domain, and administrative roles.
     * @param name_ ERC-20 token name.
     * @param symbol_ ERC-20 token symbol.
     * @param admin Address receiving initial administrative and operational roles.
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address admin
    ) public initializer {
        if (admin == address(0)) revert InvalidAddress();

        __ERC20_init(name_, symbol_);
        __EIP712_init(name_, "1");
        __ERC20Votes_init();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    /**
     * @notice Links the VehicleProfitPool contract so transfers automatically checkpoint pending yield.
     * @param _profitPool Address of the VehicleProfitPool proxy.
     */
    function setProfitPool(address _profitPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_profitPool == address(0)) revert InvalidAddress();
        address oldPool = address(profitPool);
        profitPool = IProfitPoolRewardHook(_profitPool);
        emit ProfitPoolUpdated(oldPool, _profitPool);
    }

    /**
     * @notice Registers a commercial vehicle or sub-fleet under an SPV and mints RWA ownership units.
     * @param assetId Unique identifier hash for the vehicle asset.
     * @param spvEntity Legal SPV custody address receiving initial units.
     * @param totalUnits Number of RWA token units (18 decimals) to mint.
     */
    function registerVehicle(
        bytes32 assetId,
        address spvEntity,
        uint256 totalUnits
    ) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (vehicles[assetId].registered) revert VehicleAlreadyRegistered(assetId);
        if (spvEntity == address(0)) revert InvalidAddress();
        if (totalUnits == 0) revert InvalidUnits();

        vehicles[assetId] = VehicleAsset({
            assetId: assetId,
            spvEntity: spvEntity,
            totalUnits: totalUnits,
            registered: true,
            active: true
        });
        registeredAssetIds.push(assetId);

        _mint(spvEntity, totalUnits);

        emit VehicleRegistered(assetId, spvEntity, totalUnits);
    }

    /**
     * @notice Activates or deactivates a registered vehicle asset (e.g., total loss or retirement).
     */
    function setVehicleActive(bytes32 assetId, bool active) external onlyRole(OPERATOR_ROLE) {
        if (!vehicles[assetId].registered) revert VehicleNotRegistered(assetId);
        vehicles[assetId].active = active;
        emit VehicleStatusUpdated(assetId, active);
    }

    /**
     * @notice Updates KYC/compliance whitelist status for a single investor or SPV account.
     */
    function setWhitelist(address account, bool status) external onlyRole(COMPLIANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        isWhitelisted[account] = status;
        emit WhitelistUpdated(account, status);
    }

    /**
     * @notice Batch updates KYC/compliance whitelist status to reduce onboarding gas costs.
     */
    function batchSetWhitelist(
        address[] calldata accounts,
        bool status
    ) external onlyRole(COMPLIANCE_ROLE) {
        uint256 len = accounts.length;
        for (uint256 i = 0; i < len; ) {
            address account = accounts[i];
            if (account == address(0)) revert InvalidAddress();
            isWhitelisted[account] = status;
            emit WhitelistUpdated(account, status);
            unchecked {
                ++i;
            }
        }
    }

    function registeredAssetsCount() external view returns (uint256) {
        return registeredAssetIds.length;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @dev Enforces compliance whitelisting on secondary transfers and syncs profit pool earnings
     *      BEFORE balances change to prevent retroactive yield distortion or lost rewards.
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override(ERC20Upgradeable, ERC20VotesUpgradeable) whenNotPaused {
        if (from != address(0) && to != address(0)) {
            if (!isWhitelisted[from]) revert AccountNotWhitelisted(from);
            if (!isWhitelisted[to]) revert AccountNotWhitelisted(to);
        }

        IProfitPoolRewardHook pool = profitPool;
        if (address(pool) != address(0)) {
            if (from != address(0)) {
                pool.updateEarnings(from);
            }
            if (to != address(0) && to != from) {
                pool.updateEarnings(to);
            }
        }

        super._update(from, to, value);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    uint256[45] private __gap;
}
