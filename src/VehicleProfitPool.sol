// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IERC20Payment {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IVehicleRegistryView {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title VehicleProfitPool
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice UUPS upgradeable financial waterfall contract handling OPEX, insurance reserves,
 *         operator revenue share, and 1e27-precision pro-rata investor yield distribution.
 */
contract VehicleProfitPool is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e27;
    uint256 public constant BPS_DENOMINATOR = 10_000;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    uint256 private _reentrancyStatus;

    IERC20Payment public paymentToken;
    IVehicleRegistryView public vehicleRegistry;

    address public operatorWallet;
    address public insuranceVault;

    uint256 public investorShareBps;
    uint256 public rewardPerShare;
    uint256 public totalInvestorRewardsDistributed;

    mapping(address => uint256) public rewards;
    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(bytes32 => bool) public periodFinalized;

    event PeriodFinalized(
        bytes32 indexed periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve,
        uint256 investorPool,
        uint256 operatorShare
    );
    event RewardClaimed(address indexed investor, uint256 amount);
    event WalletsUpdated(address indexed operatorWallet, address indexed insuranceVault);
    event InvestorShareBpsUpdated(uint256 oldShareBps, uint256 newShareBps);

    error InvalidAddress();
    error InvalidPeriodId();
    error PeriodAlreadyFinalized(bytes32 periodId);
    error DeductionsExceedRevenue(uint256 grossRevenue, uint256 totalDeductions);
    error ZeroTotalSupply();
    error NoRewardsAvailable();
    error InvalidShareBps(uint256 shareBps);
    error ReentrantCall();
    error SafeTransferFailed();
    error SafeTransferFromFailed();

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) revert ReentrantCall();
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the financial waterfall pool with a default 50/50 net profit split.
     * @param _paymentToken ERC-20 stablecoin address used for revenue settlement and yield payouts.
     * @param _vehicleRegistry Address of the VehicleRWARegistry proxy.
     * @param _operatorWallet Destination wallet for OPEX reimbursement and operator profit share.
     * @param _insuranceVault Address of MaintenanceAndInsuranceVault receiving periodic reserves.
     * @param admin Address receiving initial administrative, auditor, and upgrader roles.
     */
    function initialize(
        address _paymentToken,
        address _vehicleRegistry,
        address _operatorWallet,
        address _insuranceVault,
        address admin
    ) public initializer {
        if (
            _paymentToken == address(0) ||
            _vehicleRegistry == address(0) ||
            _operatorWallet == address(0) ||
            _insuranceVault == address(0) ||
            admin == address(0)
        ) revert InvalidAddress();

        __AccessControl_init();
        __Pausable_init();

        _reentrancyStatus = _NOT_ENTERED;
        paymentToken = IERC20Payment(_paymentToken);
        vehicleRegistry = IVehicleRegistryView(_vehicleRegistry);
        operatorWallet = _operatorWallet;
        insuranceVault = _insuranceVault;
        investorShareBps = 5000;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    /**
     * @notice Executes the financial waterfall for a verified operational period.
     * @param periodId Unique identifier hash for the settlement period.
     * @param grossRevenue Total gross fleet revenue collected for the period.
     * @param opex Operational expenses (fuel, driver costs, routine running costs).
     * @param reserve Allocation transferred directly to MaintenanceAndInsuranceVault.
     */
    function finalizePeriod(
        bytes32 periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve
    ) external onlyRole(AUDITOR_ROLE) whenNotPaused nonReentrant {
        if (periodId == bytes32(0)) revert InvalidPeriodId();
        if (periodFinalized[periodId]) revert PeriodAlreadyFinalized(periodId);

        uint256 totalDeductions = opex + reserve;
        if (grossRevenue < totalDeductions) {
            revert DeductionsExceedRevenue(grossRevenue, totalDeductions);
        }

        uint256 netProfit = grossRevenue - totalDeductions;
        uint256 investorPool = (netProfit * investorShareBps) / BPS_DENOMINATOR;
        uint256 operatorShare = netProfit - investorPool;

        uint256 totalTokens = 0;
        if (investorPool > 0) {
            totalTokens = vehicleRegistry.totalSupply();
            if (totalTokens == 0) revert ZeroTotalSupply();
        }

        periodFinalized[periodId] = true;

        if (investorPool > 0) {
            rewardPerShare += (investorPool * PRECISION) / totalTokens;
            totalInvestorRewardsDistributed += investorPool;
        }

        address token = address(paymentToken);

        if (opex > 0) {
            _safeTransferFrom(token, msg.sender, operatorWallet, opex);
        }

        if (reserve > 0) {
            _safeTransferFrom(token, msg.sender, insuranceVault, reserve);
        }

        if (operatorShare > 0) {
            _safeTransferFrom(token, msg.sender, operatorWallet, operatorShare);
        }

        if (investorPool > 0) {
            _safeTransferFrom(token, msg.sender, address(this), investorPool);
        }

        emit PeriodFinalized(
            periodId,
            grossRevenue,
            opex,
            reserve,
            investorPool,
            operatorShare
        );
    }

    /**
     * @notice Returns total claimable yield for an investor account.
     */
    function earned(address account) public view returns (uint256) {
        uint256 balance = vehicleRegistry.balanceOf(account);
        return
            rewards[account] +
            ((balance * (rewardPerShare - userRewardPerSharePaid[account])) / PRECISION);
    }

    /**
     * @notice Checkpoints accrued yield for an account. Automatically invoked by VehicleRWARegistry on transfers.
     */
    function updateEarnings(address account) public {
        rewards[account] = earned(account);
        userRewardPerSharePaid[account] = rewardPerShare;
    }

    /**
     * @notice Claims all accrued payment token rewards for the caller.
     */
    function claimReward() external nonReentrant whenNotPaused {
        updateEarnings(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward == 0) revert NoRewardsAvailable();

        rewards[msg.sender] = 0;
        _safeTransfer(address(paymentToken), msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    /**
     * @notice Updates operator and insurance vault destination wallets.
     */
    function setWallets(
        address _operatorWallet,
        address _insuranceVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_operatorWallet == address(0) || _insuranceVault == address(0)) {
            revert InvalidAddress();
        }
        operatorWallet = _operatorWallet;
        insuranceVault = _insuranceVault;
        emit WalletsUpdated(_operatorWallet, _insuranceVault);
    }

    /**
     * @notice Updates investor net profit share in basis points (e.g., 5000 = 50%).
     */
    function setInvestorShareBps(uint256 newShareBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newShareBps > BPS_DENOMINATOR) revert InvalidShareBps(newShareBps);
        uint256 oldShareBps = investorShareBps;
        investorShareBps = newShareBps;
        emit InvestorShareBpsUpdated(oldShareBps, newShareBps);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert SafeTransferFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Payment.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFailed();
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (token.code.length == 0) revert SafeTransferFromFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Payment.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFromFailed();
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    uint256[43] private __gap;
}
