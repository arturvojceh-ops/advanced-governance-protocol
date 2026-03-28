// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./GovernanceToken.sol";
import "./GovernanceCore.sol";

/**
 * @title VotingAnalytics
 * @dev Comprehensive analytics and insights platform for governance voting
 * @notice Provides real-time analytics, voting patterns, and governance metrics
 * @author Advanced Governance Protocol
 */
contract VotingAnalytics is Ownable, ReentrancyGuard, Pausable {
    
    // ======== STATE VARIABLES ========
    
    GovernanceToken public immutable governanceToken;
    GovernanceCore public immutable governanceCore;
    
    // Analytics data structures
    struct VotingSession {
        uint256 proposalId;
        uint256 startTime;
        uint256 endTime;
        uint256 totalParticipants;
        uint256 totalVotes;
        uint256 totalForVotes;
        uint256 totalAgainstVotes;
        uint256 totalAbstainVotes;
        uint256 quorumReached;
        uint256 averageVoteWeight;
        uint256 maxVoteWeight;
        uint256 minVoteWeight;
    }
    
    struct VoterProfile {
        address voter;
        uint256 totalVotesCast;
        uint256 totalProposalsVoted;
        uint256 totalQuadraticVotes;
        uint256 votingPower;
        uint8 governanceTier;
        uint256 firstVoteTimestamp;
        uint256 lastVoteTimestamp;
        uint256 votingFrequency;
        bool isActive;
    }
    
    struct ProposalMetrics {
        uint256 proposalId;
        uint256 creationTimestamp;
        uint256 votingStartTimestamp;
        uint256 votingEndTimestamp;
        uint256 executionTimestamp;
        uint256 totalParticipants;
        uint256 totalVotes;
        uint256 participationRate;
        uint256 quorumPercentage;
        uint256 approvalRate;
        uint256 averageVoteWeight;
        uint256 votingPowerDistribution;
        uint256 category;
        bool executed;
        bool cancelled;
    }
    
    struct TrendData {
        uint256 timestamp;
        uint256 dailyVotes;
        uint256 dailyParticipants;
        uint256 dailyProposals;
        uint256 averageVoteWeight;
        uint256 participationRate;
    }
    
    // Storage mappings
    mapping(uint256 => VotingSession) public votingSessions;
    mapping(address => VoterProfile) public voterProfiles;
    mapping(uint256 => ProposalMetrics) public proposalMetrics;
    mapping(uint256 => TrendData[]) public dailyTrends;
    mapping(address => uint256[]) public voterProposalHistory;
    mapping(uint8 => uint256) public tierDistribution;
    
    // Global analytics
    uint256 public totalVotingSessions;
    uint256 public totalUniqueVoters;
    uint256 public totalVotesEver;
    uint256 public averageParticipationRate;
    uint256 public averageVotingPower;
    uint256 public mostActiveDay;
    uint256 public highestParticipationRate;
    uint256 public lastAnalyticsUpdate;
    
    // Category analytics
    mapping(uint8 => uint256) public categoryProposalCount;
    mapping(uint8 => uint256) public categoryExecutionRate;
    mapping(uint8 => uint256) public categoryAverageParticipation;
    
    // ======== EVENTS ========
    
    event VotingSessionStarted(uint256 indexed proposalId, uint256 timestamp);
    event VotingSessionEnded(uint256 indexed proposalId, uint256 totalVotes, uint256 participants);
    event VoterProfileUpdated(address indexed voter, uint256 totalVotes, uint8 tier);
    event AnalyticsDataUpdated(string metric, uint256 oldValue, uint256 newValue);
    event TrendDataRecorded(uint256 timestamp, uint256 dailyVotes, uint256 participants);
    event CategoryAnalyticsUpdated(uint8 indexed category, uint256 proposals, uint256 executionRate);
    
    // ======== MODIFIERS ========
    
    modifier onlyGovernanceContract() {
        require(
            msg.sender == address(governanceCore) || msg.sender == address(governanceToken),
            "Not governance contract"
        );
        _;
    }
    
    modifier validProposal(uint256 _proposalId) {
        require(_proposalId < governanceCore.proposalCount(), "Invalid proposal");
        _;
    }
    
    // ======== CONSTRUCTOR ========
    
    constructor(
        address _governanceToken,
        address _governanceCore,
        address _owner
    ) Ownable(_owner) {
        governanceToken = GovernanceToken(_governanceToken);
        governanceCore = GovernanceCore(_governanceCore);
        lastAnalyticsUpdate = block.timestamp;
    }
    
    // ======== VOTING SESSION TRACKING ========
    
    /**
     * @dev Start tracking a voting session
     */
    function startVotingSession(uint256 _proposalId) 
        external 
        onlyGovernanceContract 
        validProposal(_proposalId)
    {
        require(votingSessions[_proposalId].startTime == 0, "Session already started");
        
        votingSessions[_proposalId] = VotingSession({
            proposalId: _proposalId,
            startTime: block.timestamp,
            endTime: 0,
            totalParticipants: 0,
            totalVotes: 0,
            totalForVotes: 0,
            totalAgainstVotes: 0,
            totalAbstainVotes: 0,
            quorumReached: 0,
            averageVoteWeight: 0,
            maxVoteWeight: 0,
            minVoteWeight: type(uint256).max
        });
        
        totalVotingSessions++;
        
        emit VotingSessionStarted(_proposalId, block.timestamp);
    }
    
    /**
     * @dev End voting session and calculate metrics
     */
    function endVotingSession(uint256 _proposalId) 
        external 
        onlyGovernanceContract 
        validProposal(_proposalId)
    {
        VotingSession storage session = votingSessions[_proposalId];
        require(session.startTime > 0 && session.endTime == 0, "Invalid session state");
        
        session.endTime = block.timestamp;
        
        // Calculate final metrics
        if (session.totalParticipants > 0) {
            session.averageVoteWeight = session.totalVotes / session.totalParticipants;
        }
        
        // Update proposal metrics
        _updateProposalMetrics(_proposalId);
        
        // Update global analytics
        _updateGlobalAnalytics();
        
        // Record trend data
        _recordDailyTrend();
        
        emit VotingSessionEnded(_proposalId, session.totalVotes, session.totalParticipants);
    }
    
    /**
     * @dev Record a vote in the voting session
     */
    function recordVote(
        uint256 _proposalId,
        address _voter,
        uint8 _support,
        uint256 _weight
    ) 
        external 
        onlyGovernanceContract 
        validProposal(_proposalId)
        nonReentrant
    {
        VotingSession storage session = votingSessions[_proposalId];
        require(session.startTime > 0 && session.endTime == 0, "Session not active");
        
        // Update session data
        if (session.totalParticipants == 0 || 
            !hasVoterParticipated(_proposalId, _voter)) {
            session.totalParticipants++;
        }
        
        session.totalVotes += _weight;
        
        if (_support == 1) {
            session.totalForVotes += _weight;
        } else if (_support == 0) {
            session.totalAgainstVotes += _weight;
        } else {
            session.totalAbstainVotes += _weight;
        }
        
        // Update weight extremes
        if (_weight > session.maxVoteWeight) {
            session.maxVoteWeight = _weight;
        }
        if (_weight < session.minVoteWeight) {
            session.minVoteWeight = _weight;
        }
        
        // Update voter profile
        _updateVoterProfile(_voter, _weight);
        
        // Add to voter's proposal history
        voterProposalHistory[_voter].push(_proposalId);
    }
    
    // ======== VOTER PROFILE MANAGEMENT ========
    
    /**
     * @dev Update voter profile with new vote
     */
    function _updateVoterProfile(address _voter, uint256 _weight) internal {
        VoterProfile storage profile = voterProfiles[_voter];
        
        if (profile.voter == address(0)) {
            // Initialize new voter profile
            profile.voter = _voter;
            profile.firstVoteTimestamp = block.timestamp;
            profile.totalVotesCast = 0;
            profile.totalProposalsVoted = 0;
            profile.totalQuadraticVotes = 0;
            profile.isActive = true;
            totalUniqueVoters++;
        }
        
        // Update profile data
        profile.totalVotesCast += _weight;
        profile.totalProposalsVoted++;
        profile.lastVoteTimestamp = block.timestamp;
        profile.votingPower = governanceToken.getVotes(_voter);
        profile.governanceTier = governanceToken.governanceTiers(_voter);
        
        // Calculate voting frequency
        if (profile.firstVoteTimestamp > 0) {
            profile.votingFrequency = (block.timestamp - profile.firstVoteTimestamp) / profile.totalProposalsVoted;
        }
        
        // Update tier distribution
        tierDistribution[profile.governanceTier]++;
        
        emit VoterProfileUpdated(_voter, profile.totalVotesCast, profile.governanceTier);
    }
    
    /**
     * @dev Get comprehensive voter analytics
     */
    function getVoterAnalytics(address _voter) external view returns (
        uint256 totalVotes,
        uint256 totalProposals,
        uint256 votingPower,
        uint8 tier,
        uint256 votingFrequency,
        bool isActive,
        uint256 firstVote,
        uint256 lastVote
    ) {
        VoterProfile storage profile = voterProfiles[_voter];
        
        return (
            profile.totalVotesCast,
            profile.totalProposalsVoted,
            profile.votingPower,
            profile.governanceTier,
            profile.votingFrequency,
            profile.isActive,
            profile.firstVoteTimestamp,
            profile.lastVoteTimestamp
        );
    }
    
    // ======== PROPOSAL METRICS ========
    
    /**
     * @dev Update proposal metrics
     */
    function _updateProposalMetrics(uint256 _proposalId) internal {
        VotingSession storage session = votingSessions[_proposalId];
        ProposalMetrics storage metrics = proposalMetrics[_proposalId];
        
        if (metrics.proposalId == 0) {
            metrics.proposalId = _proposalId;
            metrics.creationTimestamp = block.timestamp; // Simplified
        }
        
        metrics.votingStartTimestamp = session.startTime;
        metrics.votingEndTimestamp = session.endTime;
        metrics.totalParticipants = session.totalParticipants;
        metrics.totalVotes = session.totalVotes;
        
        // Calculate rates
        if (session.totalVotes > 0) {
            metrics.approvalRate = (session.totalForVotes * 10000) / session.totalVotes;
            metrics.averageVoteWeight = session.totalVotes / session.totalParticipants;
        }
        
        // Calculate quorum
        uint256 quorum = governanceCore.quorum(block.number - 1);
        metrics.quorumPercentage = session.totalVotes > quorum ? 
            (session.totalVotes * 10000) / quorum : 0;
        
        // Update category analytics
        uint8 category = uint8(proposalMetadata[_proposalId].category);
        categoryProposalCount[category]++;
        
        if (metrics.executed) {
            categoryExecutionRate[category] = 
                (categoryExecutionRate[category] * (categoryProposalCount[category] - 1) + 10000) / 
                categoryProposalCount[category];
        }
    }
    
    // ======== GLOBAL ANALYTICS ========
    
    /**
     * @dev Update global analytics
     */
    function _updateGlobalAnalytics() internal {
        uint256 totalSessions = totalVotingSessions;
        uint256 totalVotes = 0;
        uint256 totalParticipants = 0;
        
        // Calculate totals (simplified - in production would use storage optimization)
        for (uint256 i = 0; i < totalSessions && i < 1000; i++) {
            VotingSession storage session = votingSessions[i];
            if (session.startTime > 0) {
                totalVotes += session.totalVotes;
                totalParticipants += session.totalParticipants;
            }
        }
        
        totalVotesEver = totalVotes;
        
        if (totalSessions > 0) {
            averageParticipationRate = (totalParticipants * 10000) / totalSessions;
            averageVotingPower = totalVotes / totalParticipants;
        }
        
        lastAnalyticsUpdate = block.timestamp;
        
        emit AnalyticsDataUpdated("totalVotes", totalVotesEver, totalVotes);
        emit AnalyticsDataUpdated("averageParticipation", averageParticipationRate, averageParticipationRate);
    }
    
    /**
     * @dev Record daily trend data
     */
    function _recordDailyTrend() internal {
        uint256 today = block.timestamp / 86400;
        uint256 dailyVotes = 0;
        uint256 dailyParticipants = 0;
        
        // Calculate daily metrics (simplified)
        for (uint256 i = 0; i < totalVotingSessions && i < 100; i++) {
            VotingSession storage session = votingSessions[i];
            if (session.startTime / 86400 == today) {
                dailyVotes += session.totalVotes;
                dailyParticipants += session.totalParticipants;
            }
        }
        
        TrendData memory trend = TrendData({
            timestamp: today * 86400,
            dailyVotes: dailyVotes,
            dailyParticipants: dailyParticipants,
            dailyProposals: 1, // Simplified
            averageVoteWeight: dailyParticipants > 0 ? dailyVotes / dailyParticipants : 0,
            participationRate: dailyParticipants > 0 ? (dailyParticipants * 10000) / dailyVotes : 0
        });
        
        dailyTrends[today].push(trend);
        
        emit TrendDataRecorded(today * 86400, dailyVotes, dailyParticipants);
    }
    
    // ======== PUBLIC ANALYTICS FUNCTIONS ========
    
    /**
     * @dev Get comprehensive governance analytics
     */
    function getGovernanceAnalytics() external view returns (
        uint256 totalSessions,
        uint256 uniqueVoters,
        uint256 totalVotes,
        uint256 avgParticipation,
        uint256 avgVotingPower,
        uint256 mostActiveDayVotes,
        uint256 highestParticipation
    ) {
        return (
            totalVotingSessions,
            totalUniqueVoters,
            totalVotesEver,
            averageParticipationRate,
            averageVotingPower,
            mostActiveDay,
            highestParticipationRate
        );
    }
    
    /**
     * @dev Get voting session details
     */
    function getVotingSession(uint256 _proposalId) external view returns (
        uint256 startTime,
        uint256 endTime,
        uint256 participants,
        uint256 totalVotes,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        uint256 avgWeight,
        uint256 maxWeight,
        uint256 minWeight
    ) {
        VotingSession storage session = votingSessions[_proposalId];
        
        return (
            session.startTime,
            session.endTime,
            session.totalParticipants,
            session.totalVotes,
            session.totalForVotes,
            session.totalAgainstVotes,
            session.totalAbstainVotes,
            session.averageVoteWeight,
            session.maxVoteWeight,
            session.minWeight
        );
    }
    
    /**
     * @dev Get tier distribution
     */
    function getTierDistribution() external view returns (
        uint256 bronze,
        uint256 silver,
        uint256 gold,
        uint256 platinum,
        uint256 diamond
    ) {
        return (
            tierDistribution[1], // Bronze
            tierDistribution[2], // Silver
            tierDistribution[3], // Gold
            tierDistribution[4], // Platinum
            tierDistribution[5]  // Diamond
        );
    }
    
    /**
     * @dev Get daily trends for a specific day
     */
    function getDailyTrends(uint256 _day) external view returns (TrendData[] memory) {
        return dailyTrends[_day];
    }
    
    /**
     * @dev Get voter's proposal history
     */
    function getVoterProposalHistory(address _voter) external view returns (uint256[] memory) {
        return voterProposalHistory[_voter];
    }
    
    // ======== UTILITY FUNCTIONS ========
    
    /**
     * @dev Check if voter participated in proposal
     */
    function hasVoterParticipated(uint256 _proposalId, address _voter) public view returns (bool) {
        uint256[] storage history = voterProposalHistory[_voter];
        for (uint256 i = 0; i < history.length; i++) {
            if (history[i] == _proposalId) {
                return true;
            }
        }
        return false;
    }
    
    /**
     * @dev Get top voters by voting power
     */
    function getTopVoters(uint256 _limit) external view returns (address[] memory, uint256[] memory) {
        // Simplified implementation
        // In production, would use more efficient data structures
        address[] memory voters = new address[](_limit);
        uint256[] memory powers = new uint256[](_limit);
        
        return (voters, powers);
    }
    
    /**
     * @dev Pause analytics updates
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    /**
     * @dev Unpause analytics updates
     */
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ======== FALLBACK FUNCTION ========
    
    // Storage for proposal metadata (simplified)
    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    
    struct ProposalMetadata {
        uint8 category;
        bool executed;
    }
}
