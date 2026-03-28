// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorPreventLateQuorum.sol";
import "./GovernanceToken.sol";

/**
 * @title GovernanceCore
 * @dev Advanced governance system with quadratic voting, multi-tier delegation, and enhanced security
 * @notice Implements sophisticated voting mechanisms with timelock protection
 * @author Advanced Governance Protocol
 */
contract GovernanceCore is 
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    GovernorPreventLateQuorum
{
    
    // ======== STATE VARIABLES ========
    
    // Quadratic voting parameters
    uint256 public constant QUADRATIC_VOTING_BASE = 1e18;
    uint256 public constant MAX_VOTE_WEIGHT = 1000 * 1e18;
    
    // Proposal categories with different requirements
    enum ProposalCategory {
        PARAMETER_CHANGE,
        UPGRADE,
        TREASURY,
        EMERGENCY,
        COMMUNITY
    }
    
    struct ProposalMetadata {
        ProposalCategory category;
        uint256 executionDelay;
        uint256 votingPeriod;
        uint256 quorumRequirement;
        bool requiresSupermajority;
        string description;
        bytes32 ipfsHash;
    }
    
    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    
    // Enhanced voting tracking
    mapping(uint256 => mapping(address => uint256)) public voteWeights;
    mapping(uint256 => mapping(address => bool)) public hasVotedQuadratic;
    
    // Delegation tracking for quadratic voting
    mapping(address => uint256) public delegatedQuadraticVotes;
    mapping(address => address) public quadraticDelegate;
    
    // Analytics and metrics
    uint256 public totalQuadraticVotesCast;
    uint256 public totalProposalsExecuted;
    uint256 public averageParticipationRate;
    uint256 public lastProposalTimestamp;
    
    // Emergency mechanisms
    bool public emergencyMode;
    address public emergencyExecutor;
    uint256 public emergencyModeEndBlock;
    
    // ======== EVENTS ========
    
    event QuadraticVoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint256 support,
        uint256 weight,
        uint256 quadraticWeight
    );
    
    event ProposalCategorySet(uint256 indexed proposalId, ProposalCategory category);
    event EmergencyModeActivated(uint256 endBlock, address executor);
    event EmergencyModeDeactivated();
    event DelegationUpdated(address indexed delegator, address indexed delegatee, uint256 weight);
    
    // ======== MODIFIERS ========
    
    modifier onlyEmergencyExecutor() {
        require(msg.sender == emergencyExecutor, "Not emergency executor");
        _;
    }
    
    modifier notInEmergencyMode() {
        require(!emergencyMode || block.number >= emergencyModeEndBlock, "Emergency mode active");
        _;
    }
    
    modifier validProposalCategory(ProposalCategory _category) {
        require(_category >= ProposalCategory.PARAMETER_CHANGE && _category <= ProposalCategory.COMMUNITY, "Invalid category");
        _;
    }
    
    // ======== CONSTRUCTOR ========
    
    constructor(
        GovernanceToken _token,
        TimelockController _timelock,
        address _emergencyExecutor
    )
        Governor("GovernanceCore")
        GovernorSettings(1 /* 1 block */, 50400 /* 1 week */, 1000000e18) // 1M token threshold
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(4) // 4% quorum
        GovernorTimelockControl(_timelock)
        GovernorPreventLateQuorum(50400 /* 1 week */)
    {
        emergencyExecutor = _emergencyExecutor;
    }
    
    // ======== PROPOSAL FUNCTIONS ========
    
    /**
     * @dev Create a proposal with category and metadata
     */
    function proposeWithMetadata(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalCategory category,
        uint256 executionDelay,
        uint256 votingPeriod,
        string memory ipfsHash
    ) 
        public 
        override 
        notInEmergencyMode
        returns (uint256)
    {
        uint256 proposalId = super.propose(targets, values, calldatas, description);
        
        // Set proposal metadata
        proposalMetadata[proposalId] = ProposalMetadata({
            category: category,
            executionDelay: executionDelay > 0 ? executionDelay : votingDelay(),
            votingPeriod: votingPeriod > 0 ? votingPeriod : votingPeriod(),
            quorumRequirement: _getQuorumRequirement(category),
            requiresSupermajority: _requiresSupermajority(category),
            description: description,
            ipfsHash: keccak256(bytes(ipfsHash))
        });
        
        lastProposalTimestamp = block.timestamp;
        
        emit ProposalCategorySet(proposalId, category);
        
        return proposalId;
    }
    
    /**
     * @dev Create emergency proposal
     */
    function proposeEmergency(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) 
        external 
        onlyEmergencyExecutor 
        returns (uint256)
    {
        return proposeWithMetadata(
            targets,
            values,
            calldatas,
            description,
            ProposalCategory.EMERGENCY,
            1, // 1 block delay for emergency
            7200, // 12 hours voting
            "emergency"
        );
    }
    
    // ======== QUADRATIC VOTING ========
    
    /**
     * @dev Cast quadratic vote
     */
    function castQuadraticVote(
        uint256 proposalId,
        uint8 support,
        string memory reason,
        uint256 voteWeight
    ) 
        public 
        override 
        notInEmergencyMode
        returns (uint256)
    {
        require(!hasVotedQuadratic[proposalId][msg.sender], "Already voted quadratically");
        require(voteWeight <= MAX_VOTE_WEIGHT, "Vote weight too high");
        
        address voter = msg.sender;
        uint256 weight = _getQuadraticWeight(voter, voteWeight);
        
        // Record quadratic vote
        hasVotedQuadratic[proposalId][voter] = true;
        voteWeights[proposalId][voter] = voteWeight;
        
        // Cast the vote with calculated weight
        uint256 result = _castVote(proposalId, support, reason, weight);
        
        // Update metrics
        totalQuadraticVotesCast += weight;
        
        emit QuadraticVoteCast(voter, proposalId, support, voteWeight, weight);
        
        return result;
    }
    
    /**
     * @dev Calculate quadratic voting weight
     */
    function _getQuadraticWeight(address _voter, uint256 _voteWeight) internal view returns (uint256) {
        uint256 baseWeight = getVotes(_voter);
        uint256 delegatedWeight = delegatedQuadraticVotes[_voter];
        uint256 totalWeight = baseWeight + delegatedWeight;
        
        // Apply quadratic formula: sqrt(weight * voteWeight)
        return _sqrt((totalWeight * _voteWeight * QUADRATIC_VOTING_BASE) / 1e18);
    }
    
    /**
     * @dev Delegate quadratic voting power
     */
    function delegateQuadraticVote(address _to) external {
        require(_to != msg.sender, "Cannot delegate to self");
        require(_to != address(0), "Invalid delegate");
        
        // Remove existing delegation
        if (quadraticDelegate[msg.sender] != address(0)) {
            delegatedQuadraticVotes[quadraticDelegate[msg.sender]] -= getVotes(msg.sender);
        }
        
        // Set new delegation
        quadraticDelegate[msg.sender] = _to;
        delegatedQuadraticVotes[_to] += getVotes(msg.sender);
        
        emit DelegationUpdated(msg.sender, _to, getVotes(msg.sender));
    }
    
    // ======== VOTING LOGIC OVERRIDES ========
    
    /**
     * @dev Override voting logic to support quadratic voting
     */
    function _castVote(
        uint256 proposalId,
        uint8 support,
        string memory reason,
        uint256 weight
    ) internal override returns (uint256) {
        return super._castVote(proposalId, support, reason, weight);
    }
    
    /**
     * @dev Override quorum calculation for different categories
     */
    function quorum(uint256 blockNumber) public view override returns (uint256) {
        uint256 baseQuorum = super.quorum(blockNumber);
        
        // Adjust quorum based on proposal category if active
        // This would require tracking current proposal category
        // For now, return base quorum
        
        return baseQuorum;
    }
    
    /**
     * @dev Override voting delay for different proposal categories
     */
    function votingDelay() public view override returns (uint256) {
        // Could implement category-specific delays
        return super.votingDelay();
    }
    
    /**
     * @dev Override voting period for different proposal categories
     */
    function votingPeriod() public view override returns (uint256) {
        // Could implement category-specific periods
        return super.votingPeriod();
    }
    
    // ======== EXECUTION LOGIC ========
    
    /**
     * @dev Execute proposal with category-specific checks
     */
    function execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) 
        public 
        payable 
        override 
        notInEmergencyMode
    {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);
        
        // Check category-specific requirements
        ProposalMetadata memory metadata = proposalMetadata[proposalId];
        if (metadata.requiresSupermajority) {
            require(_hasSupermajority(proposalId), "Supermajority required");
        }
        
        super.execute(targets, values, calldatas, descriptionHash);
        
        totalProposalsExecuted++;
    }
    
    // ======== EMERGENCY FUNCTIONS ========
    
    /**
     * @dev Activate emergency mode
     */
    function activateEmergencyMode(uint256 _durationBlocks) external onlyEmergencyExecutor {
        require(!emergencyMode, "Emergency mode already active");
        
        emergencyMode = true;
        emergencyModeEndBlock = block.number + _durationBlocks;
        
        emit EmergencyModeActivated(emergencyModeEndBlock, msg.sender);
    }
    
    /**
     * @dev Deactivate emergency mode
     */
    function deactivateEmergencyMode() external onlyEmergencyExecutor {
        require(emergencyMode, "Emergency mode not active");
        require(block.number >= emergencyModeEndBlock, "Emergency period not ended");
        
        emergencyMode = false;
        emergencyModeEndBlock = 0;
        
        emit EmergencyModeDeactivated();
    }
    
    /**
     * @dev Emergency execution bypass
     */
    function emergencyExecute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) 
        external 
        payable 
        onlyEmergencyExecutor 
    {
        require(emergencyMode, "Emergency mode not active");
        
        // Bypass normal checks and execute directly
        _execute(targets, values, calldatas, descriptionHash);
    }
    
    // ======== ANALYTICS FUNCTIONS ========
    
    /**
     * @dev Get comprehensive governance analytics
     */
    function getGovernanceAnalytics() external view returns (
        uint256 _totalProposals,
        uint256 _totalExecuted,
        uint256 _totalQuadraticVotes,
        uint256 _averageParticipation,
        uint256 _activeDelegations,
        bool _emergencyMode
    ) {
        _totalProposals = proposalCount();
        _totalExecuted = totalProposalsExecuted;
        _totalQuadraticVotes = totalQuadraticVotesCast;
        _averageParticipation = averageParticipationRate;
        _activeDelegations = _getActiveDelegations();
        _emergencyMode = emergencyMode;
    }
    
    /**
     * @dev Get proposal statistics
     */
    function getProposalStats(uint256 _proposalId) external view returns (
        bool _exists,
        ProposalCategory _category,
        uint256 _forVotes,
        uint256 _againstVotes,
        uint256 _abstainVotes,
        uint256 _quorumVotes,
        bool _executed,
        bool _canceled
    ) {
        require(_proposalId < proposalCount(), "Invalid proposal ID");
        
        _exists = true;
        _category = proposalMetadata[_proposalId].category;
        _forVotes = proposalVotes(_proposalId, 1);
        _againstVotes = proposalVotes(_proposalId, 0);
        _abstainVotes = proposalVotes(_proposalId, 2);
        _quorumVotes = quorumVotes(_proposalId);
        _executed = state(_proposalId) == ProposalState.Executed;
        _canceled = state(_proposalId) == ProposalState.Canceled;
    }
    
    // ======== INTERNAL HELPER FUNCTIONS ========
    
    function _getQuorumRequirement(ProposalCategory _category) internal pure returns (uint256) {
        if (_category == ProposalCategory.EMERGENCY) {
            return 1; // 0.01% for emergency
        } else if (_category == ProposalCategory.UPGRADE) {
            return 10; // 10% for upgrades
        } else if (_category == ProposalCategory.TREASURY) {
            return 5; // 5% for treasury
        } else {
            return 4; // 4% default
        }
    }
    
    function _requiresSupermajority(ProposalCategory _category) internal pure returns (bool) {
        return _category == ProposalCategory.UPGRADE || _category == ProposalCategory.EMERGENCY;
    }
    
    function _hasSupermajority(uint256 _proposalId) internal view returns (bool) {
        uint256 totalVotes = proposalVotes(_proposalId, 1) + proposalVotes(_proposalId, 0);
        uint256 forVotes = proposalVotes(_proposalId, 1);
        
        return (forVotes * 100) / totalVotes >= 67; // 67% supermajority
    }
    
    function _getActiveDelegations() internal view returns (uint256) {
        // Simplified implementation
        // In production, would track active delegations
        return totalQuadraticVotesCast / 1000;
    }
    
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
    
    // ======== REQUIRED OVERRIDES ========
    
    function _execute(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override {
        super._execute(targets, values, calldatas, descriptionHash);
    }
    
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override {
        super._cancel(targets, values, calldatas, descriptionHash);
    }
    
    function state(uint256 proposalId) public view override returns (ProposalState) {
        return super.state(proposalId);
    }
    
    function proposalVotes(
        uint256 proposalId,
        uint8 support
    ) public view override returns (uint256) {
        return super.proposalVotes(proposalId, support);
    }
    
    function proposalThreshold() public view override returns (uint256) {
        return super.proposalThreshold();
    }
    
    function proposalDeadline(uint256 proposalId) public view override returns (uint256) {
        return super.proposalDeadline(proposalId);
    }
    
    function hasVoted(uint256 proposalId, address account) public view override returns (bool) {
        return super.hasVoted(proposalId, account);
    }
    
    // ======== STRING UTILITIES ========
    
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
