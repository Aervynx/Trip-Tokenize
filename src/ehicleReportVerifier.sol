// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Token {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IVehicleProfitPool {
    function finalizePeriod(
        bytes32 periodId,
        uint256 grossRevenue,
        uint256 opex,
        uint256 reserve
    ) external;
}

/**
 * @title VehicleReportVerifier
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice EIP-712 multi-signature verifier for off-chain commercial fleet financial reports.
 */
contract VehicleReportVerifier {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant ORACLE_SIGNER_ROLE = keccak256("ORACLE_SIGNER_ROLE");

    bytes32 public constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 public constant REPORT_TYPEHASH = keccak256(
        "PeriodReport(bytes32 periodId,uint256 grossRevenue,uint256 opex,uint256 reserve,uint256 fleetHealthIndex,bytes32 telemetryRoot,uint256 deadline,uint256 nonce)"
    );

    bytes32 private constant NAME_HASH = keccak256("AervynxVehicleReportVerifier");
    bytes32 private constant VERSION_HASH = keccak256("1");
    uint256 private constant SECP256K1N_HALF =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    struct PeriodReport {
        bytes32 periodId;
        uint256 grossRevenue;
        uint256 opex;
        uint256 reserve;
        uint256 fleetHealthIndex;
        bytes32 telemetryRoot;
        uint256 deadline;
        uint256 nonce;
    }

    IERC20Token public immutable paymentToken;
    IVehicleProfitPool public profitPool;

    uint256 public signatureThreshold;
    uint256 public currentNonce;
    bool public paused;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(bytes32 => bool) public verifiedPeriods;
    mapping(bytes32 => bytes32) public periodReportHashes;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event ProfitPoolUpdated(address indexed oldPool, address indexed newPool);
    event ReportVerifiedAndSettled(
        bytes32 indexed periodId,
        bytes32 indexed reportHash,
        uint256 grossRevenue,
        uint256 fleetHealthIndex,
        uint256 validSigners
    );

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: unauthorized");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Verifier: paused");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    constructor(
        address _paymentToken,
        address _profitPool,
        address admin,
        uint256 _signatureThreshold
    ) {
        require(_paymentToken != address(0), "Invalid payment token");
        require(_profitPool != address(0), "Invalid profit pool");
        require(admin != address(0), "Invalid admin");
        require(_signatureThreshold >= 1, "Threshold must be >= 1");

        _reentrancyStatus = _NOT_ENTERED;
        paymentToken = IERC20Token(_paymentToken);
        profitPool = IVehicleProfitPool(_profitPool);
        signatureThreshold = _signatureThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ORACLE_SIGNER_ROLE, admin);
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

        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = _recoverSigner(digest, signatures[i]);
            if (!_roles[ORACLE_SIGNER_ROLE][signer]) {
                return (false, validCount);
            }
            for (uint256 j = 0; j < validCount; j++) {
                if (seen[j] == signer) {
                    return (false, validCount);
                }
            }
            seen[validCount] = signer;
            validCount++;
        }

        return (validCount >= signatureThreshold, validCount);
    }

    /**
     * @notice Verifies multi-sig EIP-712 report and triggers settlement on VehicleProfitPool.
     */
    function submitAndSettleReport(
        PeriodReport calldata report,
        bytes[] calldata signatures
    ) external whenNotPaused nonReentrant {
        require(report.periodId != bytes32(0), "Invalid periodId");
        require(!verifiedPeriods[report.periodId], "Period already verified");
        require(block.timestamp <= report.deadline, "Report expired");
        require(report.nonce == currentNonce, "Invalid nonce");
        require(report.fleetHealthIndex <= 100, "Health index exceeds 100");
        require(report.grossRevenue >= report.opex + report.reserve, "Invalid financials");

        (bool valid, uint256 validCount) = verifySignatures(report, signatures);
        require(valid, "Invalid or insufficient oracle signatures");

        bytes32 structHash = hashReport(report);
        verifiedPeriods[report.periodId] = true;
        periodReportHashes[report.periodId] = structHash;
        currentNonce++;

        if (report.grossRevenue > 0) {
            _safeTransferFrom(address(paymentToken), msg.sender, address(this), report.grossRevenue);
            _safeApprove(address(paymentToken), address(profitPool), report.grossRevenue);
        }

        profitPool.finalizePeriod(
            report.periodId,
            report.grossRevenue,
            report.opex,
            report.reserve
        );

        if (report.grossRevenue > 0) {
            _safeApprove(address(paymentToken), address(profitPool), 0);
        }

        emit ReportVerifiedAndSettled(
            report.periodId,
            structHash,
            report.grossRevenue,
            report.fleetHealthIndex,
            validCount
        );
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(account != address(0), "Invalid account");
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    function setSignatureThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newThreshold >= 1, "Threshold must be >= 1");
        uint256 old = signatureThreshold;
        signatureThreshold = newThreshold;
        emit ThresholdUpdated(old, newThreshold);
    }

    function setProfitPool(address newPool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPool != address(0), "Invalid pool");
        address old = address(profitPool);
        profitPool = IVehicleProfitPool(newPool);
        emit ProfitPoolUpdated(old, newPool);
    }

    function setPaused(bool _paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = _paused;
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _recoverSigner(bytes32 digest, bytes memory sig) internal pure returns (address) {
        require(sig.length == 65, "Invalid signature length");
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
        require(v == 27 || v == 28, "Invalid signature v");
        require(uint256(s) <= SECP256K1N_HALF, "Invalid signature s");

        address signer = ecrecover(digest, v, r, s);
        require(signer != address(0), "Invalid signer");
        return signer;
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Token.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom failed");
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Token.approve.selector, spender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeApprove failed");
    }
}
