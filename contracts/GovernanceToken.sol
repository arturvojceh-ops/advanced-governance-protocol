// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GovernanceToken
 * @dev Advanced ERC20 token with voting capabilities, delegation, and governance features
 * @notice This token implements quadratic voting and delegation mechanisms
 * @author Advanced Governance Protocol
 */
contract GovernanceToken is ERC20Votes, Ownable, ERC20Permit, ReentrancyGuard {
    
    // ======== STATE VARIABLES ========
    
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10**18; // 1B tokens
    
    // Governance tiers with different voting weights
    mapping(address => uint8) public governanceTiers;
    uint8 public constant TIER_BRONZE = 1;
    uint8 public constant TIER_SILVER = 2;
    uint8 public constant TIER_GOLD = 3;
    uint8 public constant TIER_PLATINUM = 4;
    uint8 public constant TIER_DIAMOND = 5;
    
    // Tier voting multipliers (basis points, 10000 = 1x)
    mapping(uint8 => uint16) public tierMultipliers;
    
    // Delegation tracking
    mapping(address => address) public delegators;
    mapping(address => uint256) public delegationTimestamp;
    mapping(address => uint256) public delegationLockPeriod;
    
    // Voting power tracking with quadratic voting
    mapping(address => uint256) public votingPower;
    mapping(address => uint256) public votingCredits;
    mapping(address => uint256) public lastVotingBlock;
    
    // Analytics tracking
    uint256 public totalProposalsCreated;
    uint256 public totalVotesCast;
    uint256 public totalDelegations;
    
    // ======== EVENTS ========
    
    event TierUpgraded(address indexed user, uint8 oldTier, uint8 newTier);
    event Delegated(address indexed from, address indexed to, uint256 amount);
    event Undelegated(address indexed from, address indexed to, uint256 amount);
    event VotingCreditsIssued(address indexed user, uint256 credits);
    event VotingCreditsUsed(address indexed user, uint256 credits);
    event GovernanceParametersUpdated(string parameter, uint256 oldValue, uint256 newValue);
    
    // ======== MODIFIERS ========
    
    modifier onlyValidTier(uint8 _tier) {
        require(_tier >= TIER_BRONZE && _tier <= TIER_DIAMOND, "Invalid tier");
        _;
    }
    
    modifier onlyDelegator(address _account) {
        require(delegators[_account] != address(0), "Not a delegator");
        _;
    }
    
    modifier onlyWithVotingPower(address _account) {
        require(getVotes(_account) > 0, "No voting power");
        _;
    }
    
    // ======== CONSTRUCTOR ========
    
    constructor(
        string memory _name,
        string memory _symbol,
        address _initialOwner
    ) ERC20(_name, _symbol) ERC20Permit(_name) Ownable(_initialOwner) {
        // Initialize tier multipliers
        tierMultipliers[TIER_BRONZE] = 10000;  // 1x
        tierMultipliers[TIER_SILVER] = 12500;  // 1.25x
        tierMultipliers[TIER_GOLD] = 15000;    // 1.5x
        tierMultipliers[TIER_PLATINUM] = 17500; // 1.75x
        tierMultipliers[TIER_DIAMOND] = 20000;  // 2x
        
        // Mint initial supply to owner
        _mint(_initialOwner, MAX_SUPPLY);
        
        // Set owner to highest tier
        governanceTiers[_initialOwner] = TIER_DIAMOND;
    }
    
    // ======== TIER MANAGEMENT ========
    
    /**
     * @dev Upgrades user's governance tier
     * @param _user Address to upgrade
     * @param _newTier New tier level
     */
    function upgradeTier(address _user, uint8 _newTier) 
        external 
        onlyOwner 
        onlyValidTier(_newTier) 
    {
        uint8 _oldTier = governanceTiers[_user];
        require(_newTier > _oldTier, "Can only upgrade");
        
        governanceTiers[_user] = _newTier;
        
        // Update voting power
        _updateVotingPower(_user);
        
        emit TierUpgraded(_user, _oldTier, _newTier);
    }
    
    /**
     * @dev Batch upgrade multiple users' tiers
     */
    function batchUpgradeTier(address[] calldata _users, uint8[] calldata _tiers) 
        external 
        onlyOwner 
    {
        require(_users.length == _tiers.length, "Array length mismatch");
        
        for (uint256 i = 0; i < _users.length; i++) {
            upgradeTier(_users[i], _tiers[i]);
        }
    }
    
    // ======== DELEGATION SYSTEM ========
    
    /**
     * @dev Delegate voting power to another address with lock period
     * @param _to Address to delegate to
     * @param _amount Amount to delegate
     * @param _lockPeriod Lock period in blocks
     */
    function delegateWithLock(
        address _to, 
        uint256 _amount, 
        uint256 _lockPeriod
    ) 
        external 
        nonReentrant 
        onlyWithVotingPower(msg.sender)
    {
        require(_to != msg.sender, "Cannot delegate to self");
        require(_to != address(0), "Invalid delegate address");
        require(balanceOf(msg.sender) >= _amount, "Insufficient balance");
        require(_lockPeriod >= 100, "Lock period too short");
        
        // Remove existing delegation if any
        if (delegators[msg.sender] != address(0)) {
            _undelegate(msg.sender, delegators[msg.sender]);
        }
        
        // Set new delegation
        delegators[msg.sender] = _to;
        delegationTimestamp[msg.sender] = block.timestamp;
        delegationLockPeriod[msg.sender] = _lockPeriod;
        
        // Update voting power
        _updateVotingPower(msg.sender);
        _updateVotingPower(_to);
        
        // Increment delegation count
        totalDelegations++;
        
        emit Delegated(msg.sender, _to, _amount);
    }
    
    /**
     * @dev Remove delegation
     */
    function undelegate(address _to) 
        external 
        nonReentrant 
        onlyDelegator(msg.sender)
    {
        require(delegators[msg.sender] == _to, "Not delegated to this address");
        require(
            block.timestamp >= delegationTimestamp[msg.sender] + delegationLockPeriod[msg.sender],
            "Delegation still locked"
        );
        
        _undelegate(msg.sender, _to);
    }
    
    /**
     * @dev Internal undelegation function
     */
    function _undelegate(address _from, address _to) internal {
        delegators[_from] = address(0);
        delegationTimestamp[_from] = 0;
        delegationLockPeriod[_from] = 0;
        
        // Update voting power
        _updateVotingPower(_from);
        _updateVotingPower(_to);
        
        emit Undelegated(_from, _to, 0);
    }
    
    // ======== VOTING POWER CALCULATION ========
    
    /**
     * @dev Calculate voting power with tier multiplier and delegation
     */
    function getVotes(address _account) public view override returns (uint256) {
        uint256 baseVotes = super.getVotes(_account);
        
        // Apply tier multiplier
        uint8 tier = governanceTiers[_account];
        uint16 multiplier = tierMultipliers[tier];
        
        return (baseVotes * multiplier) / 10000;
    }
    
    /**
     * @dev Calculate quadratic voting power
     */
    function getQuadraticVotes(address _account) public view returns (uint256) {
        uint256 votes = getVotes(_account);
        return _sqrt(votes * 1e18) * 1e9; // Preserve precision
    }
    
    /**
     * @dev Get effective voting power including delegation
     */
    function getEffectiveVotingPower(address _account) public view returns (uint256) {
        uint256 ownPower = getVotes(_account);
        uint256 delegatedPower = 0;
        
        // Add delegated power from others
        // Note: This would require additional tracking in production
        // For demo, we'll use simplified calculation
        
        return ownPower + delegatedPower;
    }
    
    /**
     * @dev Update voting power for an account
     */
    function _updateVotingPower(address _account) internal {
        votingPower[_account] = getVotes(_account);
        
        // Issue voting credits based on tier
        uint8 tier = governanceTiers[_account];
        uint256 credits = tier * 1000; // 1K credits per tier level
        
        votingCredits[_account] += credits;
        lastVotingBlock[_account] = block.number;
        
        emit VotingCreditsIssued(_account, credits);
    }
    
    // ======== VOTING CREDITS SYSTEM ========
    
    /**
     * @dev Use voting credits for quadratic voting
     */
    function useVotingCredits(uint256 _credits) external returns (bool) {
        require(votingCredits[msg.sender] >= _credits, "Insufficient credits");
        
        votingCredits[msg.sender] -= _credits;
        totalVotesCast += _credits;
        
        emit VotingCreditsUsed(msg.sender, _credits);
        return true;
    }
    
    /**
     * @dev Get available voting credits
     */
    function getAvailableCredits(address _account) external view returns (uint256) {
        return votingCredits[_account];
    }
    
    // ======== ANALYTICS FUNCTIONS ========
    
    /**
     * @dev Get comprehensive governance analytics
     */
    function getGovernanceAnalytics() external view returns (
        uint256 _totalSupply,
        uint256 _totalProposals,
        uint256 _totalVotes,
        uint256 _totalDelegations,
        uint256 _activeDelegators,
        uint256 _diamondTierHolders
    ) {
        _totalSupply = totalSupply();
        _totalProposals = totalProposalsCreated;
        _totalVotes = totalVotesCast;
        _totalDelegations = totalDelegations;
        _activeDelegators = _getActiveDelegators();
        _diamondTierHolders = _getTierHolders(TIER_DIAMOND);
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
        bronze = _getTierHolders(TIER_BRONZE);
        silver = _getTierHolders(TIER_SILVER);
        gold = _getTierHolders(TIER_GOLD);
        platinum = _getTierHolders(TIER_PLATINUM);
        diamond = _getTierHolders(TIER_DIAMOND);
    }
    
    // ======== INTERNAL HELPER FUNCTIONS ========
    
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
    
    function _getActiveDelegators() internal view returns (uint256) {
        // Simplified implementation
        // In production, would track active delegators
        return totalDelegations;
    }
    
    function _getTierHolders(uint8 _tier) internal view returns (uint256) {
        // Simplified implementation
        // In production, would track tier holders
        return _tier == TIER_DIAMOND ? 1 : 0;
    }
    
    // ======== OVERRIDE FUNCTIONS ========
    
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._afterTokenTransfer(from, to, amount);
        
        // Update voting power for both addresses
        if (from != address(0)) {
            _updateVotingPower(from);
        }
        if (to != address(0)) {
            _updateVotingPower(to);
        }
    }
    
    // ======== OWNER FUNCTIONS ========
    
    /**
     * @dev Update tier multiplier
     */
    function updateTierMultiplier(uint8 _tier, uint16 _multiplier) 
        external 
        onlyOwner 
        onlyValidTier(_tier)
    {
        require(_multiplier >= 10000 && _multiplier <= 30000, "Invalid multiplier");
        
        uint16 oldMultiplier = tierMultipliers[_tier];
        tierMultipliers[_tier] = _multiplier;
        
        emit GovernanceParametersUpdated(
            string(abi.encodePacked("tierMultiplier_", _toString(_tier))),
            oldMultiplier,
            _multiplier
        );
    }
    
    /**
     * @dev Emergency function to reset delegation
     */
    function emergencyResetDelegation(address _user) external onlyOwner {
        if (delegators[_user] != address(0)) {
            _undelegate(_user, delegators[_user]);
        }
    }
    
    // ======== UTILITIES ========
    
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
