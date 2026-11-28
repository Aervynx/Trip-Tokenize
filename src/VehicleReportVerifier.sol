// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IERC20VerifierToken {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IVehicleProfitPoolSettle {
    function finalizePeriod(
        bytes32 periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve
    ) external;
}

interface ITelematicsReserveView {
    function getRecommendedReserveBps(bytes32 assetId) external view returns (uint256);
}

/**
 * @title VehicleReportVerifier
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice UUPS upgradeable EIP-712 multi-signature verifier for off-chain commercial fleet financial reports
 *         with optional on-chain telematics reserve floor enforcement.
 */
contract VehicleReportVerifier is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant ORACLE_SIGNER_ROLE = keccak256("ORACLE_SIGNER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "PeriodReport(bytes32 periodId,bytes32 assetId,uint256 grossRevenue,uint256 opex,uint256 reserve,uint256 fleetHealthIndex,bytes32 telemetryRoot,uint256 deadline,uint256 nonce)"
    );

    bytes32 private constant NAME_HASH = keccak256("AervynxVehicleReportVerifier");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    struct PeriodReport {
        bytes32 periodId;
        bytes32 assetId;
        uint256 grossRevenue;
        uint256 opex;
        uint256 reserve;
        uint256 fleetHealthIndex;
        bytes32 telemetryRoot;
        uint256 deadline;
        uint256 nonce;
    }

    uint256 private _reentrancyStatus;

    IERC20VerifierToken public paymentToken;
    IVehicleProfitPoolSettle public profitPool;
    ITelematicsReserveView public telematicsOracle;

    uint256 public signatureThreshold;
    uint256 public currentNonce;

    mapping(bytes32 => bool) public verifiedPeriods;
    mapping(bytes32 => bytes32) public periodReportHashes;

    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ProfitPoolUpdated(address indexed oldPool, address indexed newPool);
    event TelematicsOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event ReportVerifiedAndSettled(
        bytes32 indexed periodId,
        bytes32 indexed assetId,
        bytes32 indexed reportHash,
        uint256 grossRevenue,
        uint256 fleetHealthIndex,
        uint256 validSigners
    );

    error InvalidAddress();
    error InvalidThreshold();
    error InvalidPeriodId();
    error PeriodAlreadyVerified(bytes32 periodId);
    error ReportExpired(uint256 deadline, uint256 currentTime);
    error InvalidNonce(uint256 expected, uint256 provided);
    error InvalidHealthIndex(uint256 healthIndex);
    error InvalidFinancials();
    error ReserveBelowTelematicsFloor(uint256 providedReserve, uint256 requiredReserve);
    error InvalidOrInsufficientSignatures();
    error InvalidSignatureLength();
    error InvalidSignatureV();
    error InvalidSignatureS();
    error InvalidRecoveredSigner();
    error ReentrantCall();
    error SafeTransferFromFailed();
    error SafeApproveFailed();

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
     * @notice Initializes the EIP-712 report verifier and binds it to paymentToken and VehicleProfitPool.
     */
    function initialize(
        address _paymentToken,
        address _profitPool,
        address admin,
        uint256 _signatureThreshold
    ) public initializer {
        if (
            _paymentToken == address(0) ||
            _profitPool == address(0) ||
            admin == address(0)
        ) revert InvalidAddress();
        if (_signatureThreshold == 0) revert InvalidThreshold();

        __AccessControl_init();
        __Pausable_init();

        _reentrancyStatus = _NOT_ENTERED;
        paymentToken = IERC20VerifierToken(_paymentToken);
        profitPool = IVehicleProfitPoolSettle(_profitPool);
        signatureThreshold = _signatureThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_SIGNER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function hashReport(PeriodReport calldata report) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REPORT_TYPEHASH,
                report.periodId,
                report.assetId,
                report.grossRevenue,
                report.opex,
                report.reserve,
                report.fleetHealthIndex,
                report.telemetryRoot,
                report.deadline,
                report.nonce
            )
        );
    }

    function getDigest(PeriodReport calldata report) public view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), hashReport(report)));
    }

    function verifySignatures(
        PeriodReport calldata report,
        bytes[] calldata signatures
    ) public view returns (bool isValid, uint256 validCount) {
        if (signatures.length < signatureThreshold) {
            return (false, 0);
        }

        bytes32 digest = getDigest(report);
        address[] memory seen = new address[](signatures.length);

        for (uint256 i = 0; i < signatures.length; ) {
            address signer = _recoverSigner(digest, signatures[i]);
            if (!hasRole(ORACLE_SIGNER_ROLE, signer)) {
                return (false, validCount);
            }
            for (uint256 j = 0; j < validCount; ) {
                if (seen[j] == signer) {
                    return (false, validCount);
                }
                unchecked {
                    ++j;
                }
            }
            seen[validCount] = signer;
            unchecked {
                ++validCount;
                ++i;
            }
        }

        return (validCount >= signatureThreshold, validCount);
    }

    /**
     * @notice Verifies multi-sig EIP-712 report, checks optional telematics reserve floor, and settles on VehicleProfitPool.
     */
    function submitAndSettleReport(
        PeriodReport calldata report,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        if (report.periodId == bytes32(0)) revert InvalidPeriodId();
        if (verifiedPeriods[report.periodId]) revert PeriodAlreadyVerified(report.periodId);
        if (block.timestamp > report.deadline) {
            revert ReportExpired(report.deadline, block.timestamp);
        }
        if (report.nonce != currentNonce) revert InvalidNonce(currentNonce, report.nonce);
        if (report.fleetHealthIndex > 100) revert InvalidHealthIndex(report.fleetHealthIndex);
        if (report.grossRevenue < report.opex + report.reserve) revert InvalidFinancials();

        if (
            address(telematicsOracle) != address(0) &&
            report.assetId != bytes32(0) &&
            report.grossRevenue > 0
        ) {
            uint256 minBps = telematicsOracle.getRecommendedReserveBps(report.assetId);
            uint256 minReserve = (report.grossRevenue * minBps) / BPS_DENOMINATOR;
            if (report.reserve < minReserve) {
                revert ReserveBelowTelematicsFloor(report.reserve, minReserve);
            }
        }

        (bool valid, uint256 validCount) = verifySignatures(report, signatures);
        if (!valid) revert InvalidOrInsufficientSignatures();

        bytes32 structHash = hashReport(report);
        verifiedPeriods[report.periodId] = true;
        periodReportHashes[report.periodId] = structHash;
        currentNonce += 1;

        address token = address(paymentToken);
        address pool = address(profitPool);

        if (report.grossRevenue > 0) {
            _safeTransferFrom(token, msg.sender, address(this), report.grossRevenue);
            _safeApprove(token, pool, report.grossRevenue);
        }

        profitPool.finalizePeriod(
            report.periodId,
            report.grossRevenue,
            report.opex,
            report.reserve
        );

        if (report.grossRevenue > 0) {
            _safeApprove(token, pool, 0);
        }

        emit ReportVerifiedAndSettled(
            report.periodId,
            report.assetId,
            structHash,
            report.grossRevenue,
            report.fleetHealthIndex,
            validCount
        );
    }

    function setSignatureThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newThreshold == 0) revert InvalidThreshold();
        uint256 old = signatureThreshold;
        signatureThreshold = newThreshold;
        emit ThresholdUpdated(old, newThreshold);
    }

    function setProfitPool(address newPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newPool == address(0)) revert InvalidAddress();
        address old = address(profitPool);
        profitPool = IVehicleProfitPoolSettle(newPool);
        emit ProfitPoolUpdated(old, newPool);
    }

    /**
     * @notice Links or clears (address(0)) the TelematicsOracleSync contract for reserve floor checks.
     */
    function setTelematicsOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        address old = address(telematicsOracle);
        telematicsOracle = ITelematicsReserveView(newOracle);
        emit TelematicsOracleUpdated(old, newOracle);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function _recoverSigner(bytes32 digest, bytes memory sig) internal pure returns (address) {
        if (sig.length != 65) revert InvalidSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }

        if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) revert InvalidSignatureV();
        if (uint256(s) > SECP256K1N_HALF) revert InvalidSignatureS();

        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidRecoveredSigner();
        return signer;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        if (token.code.length == 0) revert SafeTransferFromFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20VerifierToken.transferFrom.selector, from, to, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeTransferFromFailed();
        }
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        if (token.code.length == 0) revert SafeApproveFailed();
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20VerifierToken.approve.selector, spender, amount)
        );
        if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert SafeApproveFailed();
        }
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    uint256[41] private __gap;
}
