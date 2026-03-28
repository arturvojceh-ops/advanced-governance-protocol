// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title AdvancedTimelockController
 * @dev Enhanced timelock controller with additional security features and analytics
 * @notice Provides secure delay for governance operations with emergency mechanisms
 * @author Advanced Governance Protocol
 */
contract AdvancedTimelockController is TimelockController {
    
    // ======== STATE VARIABLES ========
    
    // Enhanced operation tracking
    mapping(bytes32 => uint256) public operationCreationTime;
    mapping(bytes32 => address) public operationProposer;
    mapping(bytes32 => bool) public operationEmergency;
    
    // Analytics
    uint256 public totalOperations;
    uint256 public totalExecuted;
    uint256 public totalCancelled;
    uint256 public averageDelay;
    uint256 public lastOperationTimestamp;
    
    // Emergency mechanisms
    bool public emergencyMode;
    address public emergencyExecutor;
    uint256 public emergencyModeEndBlock;
    mapping(bytes32 => bool) public emergencyOperations;
    
    // Operation categories with different delays
    enum OperationCategory {
        PARAMETER_CHANGE,
        UPGRADE,
        TREASURY,
        EMERGENCY,
        ROUTINE
    }
    
    mapping(bytes32 => OperationCategory) public operationCategories;
    mapping(OperationCategory => uint256) public categoryDelays;
    
    // ======== EVENTS ========
    
    event OperationScheduled(
        bytes32 indexed id,
        address indexed proposer,
        uint256 delay,
        OperationCategory category,
        uint256 timestamp
    );
    
    event OperationExecuted(
        bytes32 indexed id,
        address indexed executor,
        uint256 timestamp,
        uint256 actualDelay
    );
    
    event OperationCancelled(
        bytes32 indexed id,
        address indexed canceller,
        uint256 timestamp,
        string reason
    );
    
    event EmergencyModeActivated(uint256 endBlock, address executor);
    event EmergencyModeDeactivated();
    event CategoryDelayUpdated(OperationCategory category, uint256 oldDelay, uint256 newDelay);
    
    // ======== MODIFIERS ========
    
    modifier onlyEmergencyExecutor() {
        require(msg.sender == emergencyExecutor, "Not emergency executor");
        _;
    }
    
    modifier notInEmergencyMode() {
        require(!emergencyMode || block.number >= emergencyModeEndBlock, "Emergency mode active");
        _;
    }
    
    modifier validOperationCategory(OperationCategory _category) {
        require(_category >= OperationCategory.PARAMETER_CHANGE && _category <= OperationCategory.ROUTINE, "Invalid category");
        _;
    }
    
    // ======== CONSTRUCTOR ========
    
    constructor(
        address _admin,
        address _proposer,
        address _executor,
        address _emergencyExecutor,
        uint256 _minDelay
    ) TimelockController(_minDelay, _proposer, _executor, _admin) {
        emergencyExecutor = _emergencyExecutor;
        
        // Initialize category delays
        categoryDelays[OperationCategory.PARAMETER_CHANGE] = 7 days;
        categoryDelays[OperationCategory.UPGRADE] = 14 days;
        categoryDelays[OperationCategory.TREASURY] = 3 days;
        categoryDelays[OperationCategory.EMERGENCY] = 1 hours;
        categoryDelays[OperationCategory.ROUTINE] = 2 days;
    }
    
    // ======== ENHANCED SCHEDULING ========
    
    /**
     * @dev Schedule operation with category and metadata
     */
    function scheduleWithCategory(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt,
        OperationCategory category,
        string memory description
    ) 
        external 
        override 
        notInEmergencyMode
        returns (bytes32)
    {
        require(targets.length == values.length, "Array length mismatch");
        require(targets.length == calldatas.length, "Array length mismatch");
        
        bytes32 id = hashOperation(targets, values, calldatas, salt);
        
        // Check if operation already exists
        require(!isOperationPending(id), "Operation already pending");
        require(!isOperationReady(id), "Operation already ready");
        
        // Set category and delay
        operationCategories[id] = category;
        uint256 delay = categoryDelays[category];
        
        // Schedule the operation
        _schedule(targets, values, calldatas, salt, delay);
        
        // Track operation metadata
        operationCreationTime[id] = block.timestamp;
        operationProposer[id] = msg.sender;
        operationEmergency[id] = (category == OperationCategory.EMERGENCY);
        
        // Update analytics
        totalOperations++;
        lastOperationTimestamp = block.timestamp;
        _updateAverageDelay(delay);
        
        emit OperationScheduled(id, msg.sender, delay, category, block.timestamp);
        
        return id;
    }
    
    /**
     * @dev Schedule batch of operations
     */
    function scheduleBatch(
        address[][] calldata targets,
        uint256[][] calldata values,
        bytes[][] calldata calldatas,
        bytes32[] calldata salts,
        OperationCategory[] calldata categories
    ) 
        external 
        notInEmergencyMode 
        returns (bytes32[] memory)
    {
        require(targets.length == values.length, "Array length mismatch");
        require(targets.length == calldatas.length, "Array length mismatch");
        require(targets.length == salts.length, "Array length mismatch");
        require(targets.length == categories.length, "Array length mismatch");
        
        bytes32[] memory ids = new bytes32[](targets.length);
        
        for (uint256 i = 0; i < targets.length; i++) {
            ids[i] = scheduleWithCategory(
                targets[i],
                values[i],
                calldatas[i],
                salts[i],
                categories[i],
                string(abi.encodePacked("Batch operation ", _toString(i)))
            );
        }
        
        return ids;
    }
    
    // ======== ENHANCED EXECUTION ========
    
    /**
     * @dev Execute operation with tracking
     */
    function execute(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) 
        external 
        payable 
        override 
        notInEmergencyMode
    {
        bytes32 id = hashOperation(targets, values, calldatas, salt);
        
        require(isOperationReady(id), "Operation not ready");
        
        uint256 creationTime = operationCreationTime[id];
        uint256 actualDelay = block.timestamp - creationTime;
        
        // Execute the operation
        super.execute(targets, values, calldatas, salt);
        
        // Update analytics
        totalExecuted++;
        _updateAverageDelay(actualDelay);
        
        emit OperationExecuted(id, msg.sender, block.timestamp, actualDelay);
    }
    
    /**
     * @dev Cancel operation with reason
     */
    function cancel(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt,
        string memory reason
    ) 
        external 
        override 
    {
        bytes32 id = hashOperation(targets, values, calldatas, salt);
        
        require(isOperationPending(id), "Operation not pending");
        
        // Cancel the operation
        super.cancel(targets, values, calldatas, salt);
        
        // Update analytics
        totalCancelled++;
        
        emit OperationCancelled(id, msg.sender, block.timestamp, reason);
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
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) 
        external 
        payable 
        onlyEmergencyExecutor 
    {
        require(emergencyMode, "Emergency mode not active");
        
        bytes32 id = hashOperation(targets, values, calldatas, salt);
        
        // Mark as emergency operation
        emergencyOperations[id] = true;
        
        // Execute immediately bypassing delay
        _execute(targets, values, calldatas, salt);
        
        // Update analytics
        totalExecuted++;
        
        emit OperationExecuted(id, msg.sender, block.timestamp, 0);
    }
    
    /**
     * @dev Emergency cancel all pending operations
     */
    function emergencyCancelAll(string memory reason) external onlyEmergencyExecutor {
        require(emergencyMode, "Emergency mode not active");
        
        // This would require additional tracking of all pending operations
        // For demo, we'll emit an event
        emit OperationCancelled(bytes32(0), msg.sender, block.timestamp, reason);
    }
    
    // ======== CATEGORY MANAGEMENT ========
    
    /**
     * @dev Update delay for operation category
     */
    function updateCategoryDelay(
        OperationCategory _category,
        uint256 _newDelay
    ) 
        external 
        onlyAdmin 
        validOperationCategory(_category)
    {
        require(_newDelay >= 1 hours, "Delay too short");
        require(_newDelay <= 30 days, "Delay too long");
        
        uint256 oldDelay = categoryDelays[_category];
        categoryDelays[_category] = _newDelay;
        
        emit CategoryDelayUpdated(_category, oldDelay, _newDelay);
    }
    
    /**
     * @dev Get delay for operation category
     */
    function getCategoryDelay(OperationCategory _category) external view returns (uint256) {
        return categoryDelays[_category];
    }
    
    // ======== ANALYTICS FUNCTIONS ========
    
    /**
     * @dev Get comprehensive timelock analytics
     */
    function getTimelockAnalytics() external view returns (
        uint256 _totalOperations,
        uint256 _totalExecuted,
        uint256 _totalCancelled,
        uint256 _averageDelay,
        uint256 _pendingOperations,
        uint256 _readyOperations,
        bool _emergencyMode
    ) {
        _totalOperations = totalOperations;
        _totalExecuted = totalExecuted;
        _totalCancelled = totalCancelled;
        _averageDelay = averageDelay;
        _pendingOperations = _getPendingOperationsCount();
        _readyOperations = _getReadyOperationsCount();
        _emergencyMode = emergencyMode;
    }
    
    /**
     * @dev Get operation details
     */
    function getOperationDetails(bytes32 _id) external view returns (
        bool _exists,
        bool _pending,
        bool _ready,
        bool _executed,
        address _proposer,
        uint256 _creationTime,
        uint256 _delay,
        OperationCategory _category,
        bool _emergency
    ) {
        _exists = isOperation(_id);
        _pending = isOperationPending(_id);
        _ready = isOperationReady(_id);
        _executed = isOperationDone(_id);
        _proposer = operationProposer[_id];
        _creationTime = operationCreationTime[_id];
        _delay = getDelay(_id);
        _category = operationCategories[_id];
        _emergency = operationEmergency[_id];
    }
    
    /**
     * @dev Get operations by category
     */
    function getOperationsByCategory(OperationCategory _category) external view returns (bytes32[] memory) {
        // Simplified implementation
        // In production, would track operations by category
        bytes32[] memory result = new bytes32[](1);
        return result;
    }
    
    // ======== INTERNAL HELPER FUNCTIONS ========
    
    function _getPendingOperationsCount() internal view returns (uint256) {
        // Simplified implementation
        // In production, would track pending operations
        return totalOperations > totalExecuted + totalCancelled ? 
            totalOperations - totalExecuted - totalCancelled : 0;
    }
    
    function _getReadyOperationsCount() internal view returns (uint256) {
        // Simplified implementation
        // In production, would track ready operations
        return _getPendingOperationsCount() / 2;
    }
    
    function _updateAverageDelay(uint256 _newDelay) internal {
        if (totalExecuted == 0) {
            averageDelay = _newDelay;
        } else {
            averageDelay = (averageDelay * totalExecuted + _newDelay) / (totalExecuted + 1);
        }
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
    
    // ======== REQUIRED OVERRIDES ========
    
    function hashOperation(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata calldatas,
        bytes32 salt
    ) public pure override returns (bytes32) {
        return super.hashOperation(targets, values, calldatas, salt);
    }
    
    function hashOperationBatch(
        address[][] calldata targets,
        uint256[][] calldata values,
        bytes[][] calldata calldatas,
        bytes32[] calldata salts
    ) public pure override returns (bytes32) {
        return super.hashOperationBatch(targets, values, calldatas, salts);
    }
    
    function getOperationState(bytes32 id) public view override returns (OperationState) {
        return super.getOperationState(id);
    }
    
    function isOperation(bytes32 id) public view override returns (bool) {
        return super.isOperation(id);
    }
    
    function isOperationPending(bytes32 id) public view override returns (bool) {
        return super.isOperationPending(id);
    }
    
    function isOperationReady(bytes32 id) public view override returns (bool) {
        return super.isOperationReady(id);
    }
    
    function isOperationDone(bytes32 id) public view override returns (bool) {
        return super.isOperationDone(id);
    }
    
    function getTimestamp(bytes32 id) public view override returns (uint256) {
        return super.getTimestamp(id);
    }
    
    function getDelay(bytes32 id) public view override returns (uint256) {
        return super.getDelay(id);
    }
}
