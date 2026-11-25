// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRWAVotingToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title EmergencyGovernanceHook
 * @author Parsa Abolhasani Rad (Aervynx Ecosystem)
 * @notice Fast-track on-chain governance for total loss settlement, operator replacement, and emergency protocol actions.
 */
contract EmergencyGovernanceHook {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;

    enum ProposalType {
        TOTAL_LOSS_SETTLEMENT,
        OPERATOR_REPLACEMENT,
        EMERGENCY_PAUSE,
        PARAMETER_OVERRIDE
    }

    enum ProposalStatus {
        ACTIVE,
        PASSED,
        REJECTED,
        EXECUTED,
        CANCELLED
    }

    struct Proposal {
        uint256 id;
        ProposalType proposalType;
        bytes32 assetId;
        address proposer;
        address target;
        bytes callData;
        bytes32 evidenceHash;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        ProposalStatus status;
    }

    IRWAVotingToken public immutable votingToken;

    uint256 public votingPeriod = 48 hours;
    uint256 public quorumBps = 2000;            // 20% of total supply
    uint256 public minProposerWeightBps = 100;  // 1% of total supply to create proposal
    uint256 public nextProposalId;

    mapping(bytes32 => mapping(address => bool)) private _roles;
    mapping(address => bool) public approvedTargets;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event TargetApproved(address indexed target, bool status);
    event ProposalCreated(
        uint256 indexed proposalId,
        ProposalType proposalType,
        bytes32 indexed assetId,
        address indexed proposer,
        uint256 endTime
    );
    event VoteCast(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed guardian);
    event GovernanceConfigUpdated(uint256 votingPeriod, uint256 quorumBps, uint256 minProposerWeightBps);

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: unauthorized");
        _;
    }

    constructor(address _votingToken, address admin) {
        require(_votingToken != address(0), "Invalid token");
        require(admin != address(0), "Invalid admin");

        votingToken = IRWAVotingToken(_votingToken);
        _roles[DEFAULT_ADMIN_ROLE][admin] = true;
        _roles[GUARDIAN_ROLE][admin] = true;
    }

    function setApprovedTarget(address target, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(target != address(0), "Invalid target");
        approvedTargets[target] = status;
        emit TargetApproved(target, status);
    }

    function setGovernanceConfig(
        uint256 _votingPeriod,
        uint256 _quorumBps,
        uint256 _minProposerWeightBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_votingPeriod >= 1 hours && _votingPeriod <= 14 days, "Invalid voting period");
        require(_quorumBps >= 500 && _quorumBps <= 8000, "Invalid quorum");
        require(_minProposerWeightBps <= 2000, "Invalid proposer weight");

        votingPeriod = _votingPeriod;
        quorumBps = _quorumBps;
        minProposerWeightBps = _minProposerWeightBps;

        emit GovernanceConfigUpdated(_votingPeriod, _quorumBps, _minProposerWeightBps);
    }

    function createProposal(
        ProposalType proposalType,
        bytes32 assetId,
        address target,
        bytes calldata callData,
        bytes32 evidenceHash
    ) external returns (uint256 proposalId) {
        require(evidenceHash != bytes32(0), "Invalid evidence hash");

        if (target != address(0)) {
            require(approvedTargets[target], "Target not approved");
        }

        if (!_roles[GUARDIAN_ROLE][msg.sender]) {
            uint256 supply = votingToken.totalSupply();
            require(supply > 0, "No token supply");
            uint256 minWeight = (supply * minProposerWeightBps) / BPS_DENOMINATOR;
            require(votingToken.balanceOf(msg.sender) >= minWeight, "Insufficient voting power");
        }

        proposalId = ++nextProposalId;
        uint256 endTime = block.timestamp + votingPeriod;

        proposals[proposalId] = Proposal({
            id: proposalId,
            proposalType: proposalType,
            assetId: assetId,
            proposer: msg.sender,
            target: target,
            callData: callData,
            evidenceHash: evidenceHash,
            startTime: block.timestamp,
            endTime: endTime,
            forVotes: 0,
            againstVotes: 0,
            status: ProposalStatus.ACTIVE
        });

        emit ProposalCreated(proposalId, proposalType, assetId, msg.sender, endTime);
    }

    function castVote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "Proposal does not exist");
        require(p.status == ProposalStatus.ACTIVE, "Proposal not active");
        require(block.timestamp <= p.endTime, "Voting ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");

        uint256 weight = votingToken.balanceOf(msg.sender);
        require(weight > 0, "No voting power");

        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            p.forVotes += weight;
        } else {
            p.againstVotes += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function executeProposal(uint256 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "Proposal does not exist");
        require(p.status == ProposalStatus.ACTIVE, "Proposal not active");
        require(block.timestamp > p.endTime, "Voting still active");

        uint256 supply = votingToken.totalSupply();
        uint256 requiredQuorum = (supply * quorumBps) / BPS_DENOMINATOR;
        uint256 totalParticipation = p.forVotes + p.againstVotes;

        if (totalParticipation < requiredQuorum || p.forVotes <= p.againstVotes) {
            p.status = ProposalStatus.REJECTED;
            return;
        }

        p.status = ProposalStatus.EXECUTED;

        if (p.target != address(0) && p.callData.length > 0) {
            require(approvedTargets[p.target], "Target not approved");
            (bool success, ) = p.target.call(p.callData);
            require(success, "Proposal execution failed");
        }

        emit ProposalExecuted(proposalId, msg.sender);
    }

    function cancelProposal(uint256 proposalId) external onlyRole(GUARDIAN_ROLE) {
        Proposal storage p = proposals[proposalId];
        require(p.id != 0, "Proposal does not exist");
        require(p.status == ProposalStatus.ACTIVE, "Cannot cancel");
        p.status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(proposalId, msg.sender);
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
}
