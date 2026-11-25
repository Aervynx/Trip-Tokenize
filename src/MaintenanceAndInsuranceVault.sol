// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title MockUSDT
 * @notice Minimal ERC20 token for standalone testing inside Remix IDE.
 */
contract MockUSDT is IERC20 {
    string public constant name = "Mock Tether USD";
    string public constant symbol = "mUSDT";
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        _mint(msg.sender, 1_000_000 * 1e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "Insufficient allowance");
        unchecked {
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "Invalid recipient");
        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "Insufficient balance");
        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) internal {
        require(to != address(0), "Invalid recipient");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

/**
 * @title MaintenanceAndInsuranceVault
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Standalone escrow vault holding maintenance, insurance, and emergency repair reserves for commercial vehicle fleets.
 */
contract MaintenanceAndInsuranceVault {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant FLEET_MANAGER_ROLE = keccak256("FLEET_MANAGER_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    bool public paused;

    enum ClaimType {
        MAINTENANCE,
        INSURANCE_PREMIUM,
        ACCIDENT_REPAIR,
        EMERGENCY
    }

    enum ClaimStatus {
        PENDING,
        APPROVED_AND_PAID,
        REJECTED
    }

    struct ClaimRequest {
        uint256 claimId;
        bytes32 assetId;
        ClaimType claimType;
        address recipient;
        uint256 amount;
        bytes32 invoiceHash;
        ClaimStatus status;
        uint256 createdAt;
    }

    IERC20 public immutable paymentToken;
    uint256 public nextClaimId;
    uint256 public totalDisbursed;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(uint256 => ClaimRequest) public claims;

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event Paused(address account);
    event Unpaused(address account);
    event ReserveDeposited(address indexed sender, uint256 amount);
    event ClaimSubmitted(
        uint256 indexed claimId,
        bytes32 indexed assetId,
        ClaimType claimType,
        address indexed recipient,
        uint256 amount,
        bytes32 invoiceHash
    );
    event ClaimApprovedAndPaid(uint256 indexed claimId, address indexed recipient, uint256 amount);
    event ClaimRejected(uint256 indexed claimId, address indexed auditor);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: unauthorized account");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Pausable: paused");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    constructor(address _paymentToken, address admin) {
        require(_paymentToken != address(0), "Invalid payment token");
        require(admin != address(0), "Invalid admin");

        _reentrancyStatus = _NOT_ENTERED;
        paymentToken = IERC20(_paymentToken);

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FLEET_MANAGER_ROLE, admin);
        _grantRole(AUDITOR_ROLE, admin);
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
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

    function depositReserve(uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "Invalid amount");
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
        require(assetId != bytes32(0), "Invalid assetId");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        require(invoiceHash != bytes32(0), "Invalid invoice hash");

        claimId = ++nextClaimId;

        claims[claimId] = ClaimRequest({
            claimId: claimId,
            assetId: assetId,
            claimType: claimType,
            recipient: recipient,
            amount: amount,
            invoiceHash: invoiceHash,
            status: ClaimStatus.PENDING,
            createdAt: block.timestamp
        });

        emit ClaimSubmitted(claimId, assetId, claimType, recipient, amount, invoiceHash);
    }

    function approveAndExecuteClaim(uint256 claimId)
        external
        onlyRole(AUDITOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        ClaimRequest storage req = claims[claimId];
        require(req.claimId != 0, "Claim does not exist");
        require(req.status == ClaimStatus.PENDING, "Claim not pending");
        require(paymentToken.balanceOf(address(this)) >= req.amount, "Insufficient vault balance");

        req.status = ClaimStatus.APPROVED_AND_PAID;
        totalDisbursed += req.amount;

        _safeTransfer(address(paymentToken), req.recipient, req.amount);

        emit ClaimApprovedAndPaid(claimId, req.recipient, req.amount);
    }

    function rejectClaim(uint256 claimId) external onlyRole(AUDITOR_ROLE) whenNotPaused {
        ClaimRequest storage req = claims[claimId];
        require(req.claimId != 0, "Claim does not exist");
        require(req.status == ClaimStatus.PENDING, "Claim not pending");

        req.status = ClaimStatus.REJECTED;

        emit ClaimRejected(claimId, msg.sender);
    }

    function vaultBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom failed");
    }
}
