// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IERC20VaultToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title MaintenanceAndInsuranceVault
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice UUPS upgradeable escrow vault with rolling monthly withdrawal cap,
 *         multi-sig approvals, and a 24-hour timelock for high-value fleet expenses.
 */
contract MaintenanceAndInsuranceVault is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant FLEET_MANAGER_ROLE = keccak256("FLEET_MANAGER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant PERIOD_DURATION = 30 days;
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 24 hours;
    uint256 public constant MAX_TIMELOCK_DELAY = 7 days;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    enum ClaimType {
        MAINTENANCE,
        INSURANCE_PREMIUM,
        ACCIDENT_REPAIR,
        EMERGENCY
    }

    enum ClaimStatus {
        PENDING,
        QUEUED,
        APPROVED_AND_PAID,
        REJECTED,
        CANCELLED
    }

    struct ClaimRequest {
        uint256 claimId;
        bytes32 assetId;
        ClaimType claimType;
        address recipient;
        uint256 amount;
        bytes32 invoiceHash;
        bool isHighValue;
        uint256 approvalsCount;
        uint256 requiredApprovals;
        uint256 executableAfter;
        ClaimStatus status;
        uint256 createdAt;
    }

    uint256 private _reentrancyStatus;

    IERC20VaultToken public paymentToken;

    uint256 public monthlyWithdrawalCap;
    uint256 public currentPeriodStart;
    uint256 public currentPeriodSpent;

    uint256 public highValueThreshold;
    uint256 public requiredHighValueApprovals;
    uint256 public highValueTimelockDelay;

    uint256 public nextClaimId;
    uint256 public totalDisbursed;

    mapping(uint256 => ClaimRequest) private _claims;
    mapping(uint256 => mapping(address => bool)) public hasApprovedClaim;

    event ReserveDeposited(address indexed sender, uint256 amount);
    event MonthlyCapUpdated(uint256 oldCap, uint256 newCap);
    event HighValuePolicyUpdated(uint256 newThreshold, uint256 newRequiredApprovals);
    event TimelockDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event ClaimSubmitted(
        uint256 indexed claimId,
        bytes32 indexed assetId,
        ClaimType claimType,
        address indexed recipient,
        uint256 amount,
        bool isHighValue,
        uint256 requiredApprovals,
        bytes32 invoiceHash
    );
    event ClaimApproved(
        uint256 indexed claimId,
        address indexed auditor,
        uint256 approvalsCount,
        uint256 requiredApprovals
    );
    event ClaimQueued(uint256 indexed claimId, uint256 executableAfter);
    event ClaimApprovedAndPaid(uint256 indexed claimId, address indexed recipient, uint256 amount);
    event ClaimRejected(uint256 indexed claimId, address indexed auditor);
    event ClaimCancelled(uint256 indexed claimId, address indexed cancelledBy);

    error InvalidAddress();
    error InvalidAmount();
    error InvalidAssetId();
    error InvalidInvoiceHash();
    error InvalidPolicyParameters();
    error TimelockExceedsMax(uint256 delay, uint256 maxDelay);
    error ClaimNotFound(uint256 claimId);
    error InvalidClaimStatus(ClaimStatus current, ClaimStatus expected);
    error AlreadyApprovedByAuditor(uint256 claimId, address auditor);
    error TimelockNotExpired(uint256 currentTime, uint256 executableAfter);
    error ExceedsMonthlyWithdrawalCap(uint256 requested, uint256 remaining);
    error InsufficientVaultBalance(uint256 requested, uint256 available);
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
     * @notice Initializes the escrow vault with cap, multi-sig policy, and default 24-hour timelock.
     */
    function initialize(
        address _paymentToken,
        address admin,
        uint256 _monthlyWithdrawalCap,
        uint256 _highValueThreshold,
        uint256 _requiredHighValueApprovals
    ) public initializer {
        if (_paymentToken == address(0) || admin == address(0)) revert InvalidAddress();
        if (
            _monthlyWithdrawalCap == 0 ||
            _highValueThreshold == 0 ||
            _requiredHighValueApprovals < 2
        ) revert InvalidPolicyParameters();

        __AccessControl_init();
        __Pausable_init();

        _reentrancyStatus = _NOT_ENTERED;
        paymentToken = IERC20VaultToken(_paymentToken);

        monthlyWithdrawalCap = _monthlyWithdrawalCap;
        currentPeriodStart = block.timestamp;

        highValueThreshold = _highValueThreshold;
        requiredHighValueApprovals = _requiredHighValueApprovals;
        highValueTimelockDelay = DEFAULT_TIMELOCK_DELAY;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FLEET_MANAGER_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function setMonthlyWithdrawalCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newCap == 0) revert InvalidPolicyParameters();
        uint256 oldCap = monthlyWithdrawalCap;
        monthlyWithdrawalCap = newCap;
        emit MonthlyCapUpdated(oldCap, newCap);
    }

    function setHighValuePolicy(
        uint256 newThreshold,
        uint256 newRequiredApprovals
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0 || newRequiredApprovals < 2) revert InvalidPolicyParameters();
        highValueThreshold = newThreshold;
        requiredHighValueApprovals = newRequiredApprovals;
        emit HighValuePolicyUpdated(newThreshold, newRequiredApprovals);
    }

    function setHighValueTimelockDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay > MAX_TIMELOCK_DELAY) {
            revert TimelockExceedsMax(newDelay, MAX_TIMELOCK_DELAY);
        }
        uint256 oldDelay = highValueTimelockDelay;
        highValueTimelockDelay = newDelay;
        emit TimelockDelayUpdated(oldDelay, newDelay);
    }

    function depositReserve(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(address(paymentToken), msg.sender, address(this), amount);
        emit ReserveDeposited(msg.sender, amount);
    }

    function submitClaim(
        bytes32 assetId,
        ClaimType claimType,
        address recipient,
        uint256 amount,
        bytes32 invoiceHash
    ) external onlyRole(FLEET_MANAGER_ROLE) whenNotPaused returns (uint256 claimId) {
        if (assetId == bytes32(0)) revert InvalidAssetId();
        if (recipient == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (invoiceHash == bytes32(0)) revert InvalidInvoiceHash();

        bool highValue = amount >= highValueThreshold;
        uint256 reqApprovals = highValue ? requiredHighValueApprovals : 1;
        claimId = ++nextClaimId;

        ClaimRequest storage req = _claims[claimId];
        req.claimId = claimId;
        req.assetId = assetId;
        req.claimType = claimType;
        req.recipient = recipient;
        req.amount = amount;
        req.invoiceHash = invoiceHash;
        req.isHighValue = highValue;
        req.requiredApprovals = reqApprovals;
        req.status = ClaimStatus.PENDING;
        req.createdAt = block.timestamp;

        emit ClaimSubmitted(
            claimId,
            assetId,
            claimType,
            recipient,
            amount,
            highValue,
            reqApprovals,
            invoiceHash
        );
    }

    /**
     * @notice Approves a pending claim. Standard claims pay immediately; high-value claims enter timelock queue.
     */
    function approveClaim(uint256 claimId)
        external
        onlyRole(AUDITOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        ClaimRequest storage req = _claims[claimId];
        if (req.claimId == 0) revert ClaimNotFound(claimId);
        if (req.status != ClaimStatus.PENDING) {
            revert InvalidClaimStatus(req.status, ClaimStatus.PENDING);
        }
        if (hasApprovedClaim[claimId][msg.sender]) {
            revert AlreadyApprovedByAuditor(claimId, msg.sender);
        }

        hasApprovedClaim[claimId][msg.sender] = true;
        req.approvalsCount += 1;

        emit ClaimApproved(claimId, msg.sender, req.approvalsCount, req.requiredApprovals);

        if (req.approvalsCount >= req.requiredApprovals) {
            if (req.isHighValue && highValueTimelockDelay > 0) {
                req.status = ClaimStatus.QUEUED;
                req.executableAfter = block.timestamp + highValueTimelockDelay;
                emit ClaimQueued(claimId, req.executableAfter);
            } else {
                _executeClaim(req);
            }
        }
    }

    /**
     * @notice Executes a queued high-value claim once its timelock period has elapsed.
     */
    function executeQueuedClaim(uint256 claimId)
        external
        onlyRole(AUDITOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        ClaimRequest storage req = _claims[claimId];
        if (req.claimId == 0) revert ClaimNotFound(claimId);
        if (req.status != ClaimStatus.QUEUED) {
            revert InvalidClaimStatus(req.status, ClaimStatus.QUEUED);
        }
        if (block.timestamp < req.executableAfter) {
            revert TimelockNotExpired(block.timestamp, req.executableAfter);
        }

        _executeClaim(req);
    }

    /**
     * @notice Emergency veto allowing admin to cancel a queued high-value claim before execution.
     */
    function cancelQueuedClaim(uint256 claimId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ClaimRequest storage req = _claims[claimId];
        if (req.claimId == 0) revert ClaimNotFound(claimId);
        if (req.status != ClaimStatus.QUEUED) {
            revert InvalidClaimStatus(req.status, ClaimStatus.QUEUED);
        }

        req.status = ClaimStatus.CANCELLED;
        emit ClaimCancelled(claimId, msg.sender);
    }

    function rejectClaim(uint256 claimId) external onlyRole(AUDITOR_ROLE) whenNotPaused {
        ClaimRequest storage req = _claims[claimId];
        if (req.claimId == 0) revert ClaimNotFound(claimId);
        if (req.status != ClaimStatus.PENDING) {
            revert InvalidClaimStatus(req.status, ClaimStatus.PENDING);
        }

        req.status = ClaimStatus.REJECTED;
        emit ClaimRejected(claimId, msg.sender);
    }

    function getClaim(uint256 claimId) external view returns (ClaimRequest memory) {
        if (_claims[claimId].claimId == 0) revert ClaimNotFound(claimId);
        return _claims[claimId];
    }

    function vaultBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }

    function timeUntilExecutable(uint256 claimId) external view returns (uint256) {
        ClaimRequest storage req = _claims[claimId];
        if (req.status != ClaimStatus.QUEUED || block.timestamp >= req.executableAfter) {
            return 0;
        }
        return req.executableAfter - block.timestamp;
    }

    function remainingMonthlyAllowance() external view returns (uint256) {
        uint256 spent = block.timestamp >= currentPeriodStart + PERIOD_DURATION
            ? 0
            : currentPeriodSpent;

        if (spent >= monthlyWithdrawalCap) {
            return 0;
        }
        return monthlyWithdrawalCap - spent;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _executeClaim(ClaimRequest storage req) internal {
        _syncPeriod();

        uint256 remaining = monthlyWithdrawalCap > currentPeriodSpent
            ? monthlyWithdrawalCap - currentPeriodSpent
            : 0;
        if (req.amount > remaining) {
            revert ExceedsMonthlyWithdrawalCap(req.amount, remaining);
        }

        uint256 available = paymentToken.balanceOf(address(this));
        if (available < req.amount) {
            revert InsufficientVaultBalance(req.amount, available);
        }

        req.status = ClaimStatus.APPROVED_AND_PAID;
        currentPeriodSpent += req.amount;
        totalDisbursed += req.amount;

        _safeTransfer(address(paymentToken), req.recipient, req.amount);
        emit ClaimApprovedAndPaid(req.claimId, req.recipient, req.amount);
    }

    function _syncPeriod() internal {
        if (block.timestamp >= currentPeriodStart + PERIOD_DURATION) {
            uint256 periodsElapsed = (block.timestamp - currentPeriodStart) / PERIOD_DURATION;
            currentPeriodStart += periodsElapsed * PERIOD_DURATION;
            currentPeriodSpent = 0;
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        if (token.code.length == 0) revert SafeTransferFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20VaultToken.transfer.selector, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFailed();
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (token.code.length == 0) revert SafeTransferFromFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20VaultToken.transferFrom.selector, from, to, amount)
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

    uint256[38] private __gap;
}
