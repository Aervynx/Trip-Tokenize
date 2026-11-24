// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/access/AccessControlUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/proxy/utils/Initializable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/utils/PausableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v5.0.0/contracts/utils/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVehicleRegistry {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title VehicleProfitPool
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Manages the financial waterfall, OPEX/reserve deductions, and pro-rata yield distribution for commercial vehicle fleets.
 */
contract VehicleProfitPool is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PRECISION = 1e18;

    IERC20 public paymentToken;
    IVehicleRegistry public vehicleRegistry;

    address public operatorWallet;
    address public insuranceVault;

    uint256 public rewardPerShare;
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _paymentToken,
        address _vehicleRegistry,
        address _operatorWallet,
        address _insuranceVault,
        address admin
    ) public initializer {
        require(_paymentToken != address(0), "Invalid payment token");
        require(_vehicleRegistry != address(0), "Invalid registry");
        require(_operatorWallet != address(0), "Invalid operator wallet");
        require(_insuranceVault != address(0), "Invalid insurance vault");
        require(admin != address(0), "Invalid admin");

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        paymentToken = IERC20(_paymentToken);
        vehicleRegistry = IVehicleRegistry(_vehicleRegistry);
        operatorWallet = _operatorWallet;
        insuranceVault = _insuranceVault;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function finalizePeriod(
        bytes32 periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve
    ) external onlyRole(AUDITOR_ROLE) whenNotPaused nonReentrant {
        require(periodId != bytes32(0), "Invalid periodId");
        require(!periodFinalized[periodId], "Period already finalized");
        require(grossRevenue >= (opex + reserve), "Deductions exceed revenue");

        periodFinalized[periodId] = true;

        uint256 netProfit = grossRevenue - opex - reserve;

        if (opex > 0) {
            paymentToken.safeTransferFrom(msg.sender, operatorWallet, opex);
        }

        if (reserve > 0) {
            paymentToken.safeTransferFrom(msg.sender, insuranceVault, reserve);
        }

        uint256 investorPool = netProfit / 2;
        uint256 operatorShare = netProfit - investorPool;

        if (operatorShare > 0) {
            paymentToken.safeTransferFrom(msg.sender, operatorWallet, operatorShare);
        }

        uint256 totalTokens = vehicleRegistry.totalSupply();
        if (totalTokens > 0 && investorPool > 0) {
            paymentToken.safeTransferFrom(msg.sender, address(this), investorPool);
            rewardPerShare += (investorPool * PRECISION) / totalTokens;
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

    function earned(address account) public view returns (uint256) {
        uint256 balance = vehicleRegistry.balanceOf(account);
        return rewards[account] + ((balance * (rewardPerShare - userRewardPerSharePaid[account])) / PRECISION);
    }

    function updateEarnings(address account) public {
        rewards[account] = earned(account);
        userRewardPerSharePaid[account] = rewardPerShare;
    }

    function claimReward() external nonReentrant whenNotPaused {
        updateEarnings(msg.sender);
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards");

        rewards[msg.sender] = 0;
        paymentToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function setWallets(
        address _operatorWallet,
        address _insuranceVault
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_operatorWallet != address(0), "Invalid operator wallet");
        require(_insuranceVault != address(0), "Invalid insurance vault");

        operatorWallet = _operatorWallet;
        insuranceVault = _insuranceVault;

        emit WalletsUpdated(_operatorWallet, _insuranceVault);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}
}
