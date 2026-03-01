// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeadManSwitchModule, ISafe} from "../src/DeadManSwitchModule.sol";
import {DeadManSwitchGuard, IDeadManSwitchModule} from "../src/DeadManSwitchGuard.sol";

/// @title MockSafe
/// @notice Simulates Gnosis Safe's owner management (linked list) for unit testing.
/// @dev Implements ISafe interface plus owner management functions (swapOwner, removeOwner, changeThreshold).
contract MockSafe is ISafe {
    // ----------------------------
    // Constants
    // ----------------------------
    address internal constant SENTINEL_OWNERS = address(0x1);

    // ----------------------------
    // Storage
    // ----------------------------
    mapping(address => address) internal ownerList; // linked list: owner => next owner
    uint256 public ownerCount;
    uint256 public threshold;
    mapping(address => bool) public enabledModules;
    address public guard;

    // ----------------------------
    // Events (matching Safe)
    // ----------------------------
    event AddedOwner(address owner);
    event RemovedOwner(address owner);
    event ChangedThreshold(uint256 threshold);
    event EnabledModule(address module);
    event DisabledModule(address module);
    event ChangedGuard(address guard);
    event ExecutionFromModuleSuccess(address indexed module);
    event ExecutionFromModuleFailure(address indexed module);

    // ----------------------------
    // Setup
    // ----------------------------

    /// @notice Initialize Safe with owners and threshold
    function setup(address[] memory _owners, uint256 _threshold) external {
        require(_threshold > 0, "GS202");
        require(_threshold <= _owners.length, "GS201");

        // Build linked list: SENTINEL -> owner[0] -> owner[1] -> ... -> SENTINEL
        address currentOwner = SENTINEL_OWNERS;
        for (uint256 i = 0; i < _owners.length; i++) {
            address owner = _owners[i];
            require(owner != address(0) && owner != SENTINEL_OWNERS, "GS203");
            require(ownerList[owner] == address(0), "GS204"); // not already owner
            ownerList[currentOwner] = owner;
            currentOwner = owner;
        }
        ownerList[currentOwner] = SENTINEL_OWNERS;
        ownerCount = _owners.length;
        threshold = _threshold;
    }

    // ----------------------------
    // ISafe Implementation
    // ----------------------------

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        override
        returns (bool success)
    {
        require(enabledModules[msg.sender], "GS104"); // not enabled module
        require(operation == Operation.Call, "Only Call supported in mock");

        (success,) = to.call{value: value}(data);

        if (success) {
            emit ExecutionFromModuleSuccess(msg.sender);
        } else {
            emit ExecutionFromModuleFailure(msg.sender);
        }
    }

    function getOwners() external view override returns (address[] memory) {
        address[] memory array = new address[](ownerCount);
        uint256 index = 0;
        address currentOwner = ownerList[SENTINEL_OWNERS];
        while (currentOwner != SENTINEL_OWNERS) {
            array[index] = currentOwner;
            currentOwner = ownerList[currentOwner];
            index++;
        }
        return array;
    }

    function getThreshold() external view override returns (uint256) {
        return threshold;
    }

    // ----------------------------
    // Owner Management (called via execTransactionFromModule)
    // ----------------------------

    /// @notice Swap owner oldOwner with newOwner
    /// @param prevOwner Previous owner in the linked list (before oldOwner)
    /// @param oldOwner Owner to be replaced
    /// @param newOwner New owner to replace oldOwner
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external {
        // Only callable by self (via module execution)
        require(msg.sender == address(this), "GS031");

        // Validate newOwner
        require(newOwner != address(0) && newOwner != SENTINEL_OWNERS, "GS203");
        require(ownerList[newOwner] == address(0), "GS204"); // newOwner not already owner

        // Validate oldOwner and prevOwner relationship
        require(ownerList[prevOwner] == oldOwner, "GS205");

        // Update linked list
        ownerList[newOwner] = ownerList[oldOwner];
        ownerList[prevOwner] = newOwner;
        ownerList[oldOwner] = address(0);

        emit RemovedOwner(oldOwner);
        emit AddedOwner(newOwner);
    }

    /// @notice Remove an owner and update threshold
    /// @param prevOwner Previous owner in the linked list
    /// @param owner Owner to remove
    /// @param _threshold New threshold
    function removeOwner(address prevOwner, address owner, uint256 _threshold) external {
        // Only callable by self (via module execution)
        require(msg.sender == address(this), "GS031");

        // Threshold check
        require(ownerCount - 1 >= _threshold, "GS201");

        // Validate owner and prevOwner relationship
        require(ownerList[prevOwner] == owner, "GS205");
        require(owner != SENTINEL_OWNERS, "GS203");

        // Update linked list
        ownerList[prevOwner] = ownerList[owner];
        ownerList[owner] = address(0);
        ownerCount--;

        // Update threshold if changed
        if (threshold != _threshold) {
            threshold = _threshold;
            emit ChangedThreshold(_threshold);
        }

        emit RemovedOwner(owner);
    }

    /// @notice Change the threshold
    /// @param _threshold New threshold
    function changeThreshold(uint256 _threshold) external {
        // Only callable by self (via module execution)
        require(msg.sender == address(this), "GS031");
        require(_threshold > 0, "GS202");
        require(_threshold <= ownerCount, "GS201");

        threshold = _threshold;
        emit ChangedThreshold(_threshold);
    }

    // ----------------------------
    // Module Management
    // ----------------------------

    function enableModule(address module) external {
        require(msg.sender == address(this), "GS031");
        require(module != address(0) && module != SENTINEL_OWNERS, "GS101");
        enabledModules[module] = true;
        emit EnabledModule(module);
    }

    function disableModule(address, address module) external {
        require(msg.sender == address(this), "GS031");
        enabledModules[module] = false;
        emit DisabledModule(module);
    }

    // ----------------------------
    // Guard Management
    // ----------------------------

    function setGuard(address _guard) external {
        require(msg.sender == address(this), "GS031");
        guard = _guard;
        emit ChangedGuard(_guard);
    }

    // ----------------------------
    // Helper to simulate Safe tx (direct call as Safe)
    // ----------------------------

    /// @notice Execute arbitrary call as the Safe (for testing admin functions)
    function execAsSafe(address to, bytes calldata data) external returns (bool, bytes memory) {
        return to.call(data);
    }

    /// @notice Receive ETH
    receive() external payable {}
}

/// @title RevertingModule
/// @notice A module that reverts on notifyActivity - used to test guard resilience
contract RevertingModule is IDeadManSwitchModule {
    function notifyActivity(bytes32, bool) external pure override {
        revert("I always revert");
    }
}

/// @title DeadManSwitchModuleTest
/// @notice Unit tests for DeadManSwitchModule
contract DeadManSwitchModuleTest is Test {
    MockSafe public safe;
    DeadManSwitchModule public module;
    DeadManSwitchGuard public guard;

    address public owner1 = address(0x1001);
    address public owner2 = address(0x1002);
    address public owner3 = address(0x1003);
    address public heir = address(0x2001);
    uint256 public constant DELAY = 30 days;

    function setUp() public {
        // Deploy mock Safe with 3 owners, threshold 2
        safe = new MockSafe();
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;
        safe.setup(owners, 2);

        // Deploy module
        module = new DeadManSwitchModule(ISafe(address(safe)), heir, DELAY);

        // Enable module on Safe
        safe.execAsSafe(address(safe), abi.encodeWithSignature("enableModule(address)", address(module)));

        // Deploy guard
        guard = new DeadManSwitchGuard(IDeadManSwitchModule(address(module)), address(safe));

        // Set guard in Safe
        safe.execAsSafe(address(safe), abi.encodeWithSignature("setGuard(address)", address(guard)));

        // Set guard in module (via Safe)
        safe.execAsSafe(address(module), abi.encodeWithSignature("setGuard(address)", address(guard)));
    }

    // ============================================
    // Test 1: Deployment + Init
    // ============================================

    function test_DeploymentAndInit() public view {
        // Check module state
        assertEq(address(module.safe()), address(safe), "safe mismatch");
        assertEq(module.heir(), heir, "heir mismatch");
        assertEq(module.delay(), DELAY, "delay mismatch");
        assertEq(module.lastActivity(), block.timestamp, "lastActivity should be deployment time");
        assertEq(module.guard(), address(guard), "guard mismatch");
        assertEq(module.paused(), false, "should not be paused");

        // Check guard state
        assertEq(address(guard.module()), address(module), "guard module mismatch");
        assertEq(guard.safe(), address(safe), "guard safe mismatch");

        // Check Safe state
        assertEq(safe.threshold(), 2, "threshold mismatch");
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 3, "owner count mismatch");
        assertEq(owners[0], owner1, "owner1 mismatch");
        assertEq(owners[1], owner2, "owner2 mismatch");
        assertEq(owners[2], owner3, "owner3 mismatch");
    }

    // ============================================
    // Test 2: setGuard only by Safe
    // ============================================

    function test_SetGuard_OnlyBySafe() public {
        address newGuard = address(0x9999);

        // Non-Safe caller should revert
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotSafe.selector);
        module.setGuard(newGuard);

        // Safe can set guard
        safe.execAsSafe(address(module), abi.encodeWithSignature("setGuard(address)", newGuard));
        assertEq(module.guard(), newGuard, "guard should be updated");
    }

    // ============================================
    // Test 3: notifyActivity only guard
    // ============================================

    function test_NotifyActivity_OnlyGuard() public {
        // Non-guard caller should revert
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotGuard.selector);
        module.notifyActivity(bytes32(0), true);

        // Guard can notify
        uint256 oldActivity = module.lastActivity();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(address(guard));
        module.notifyActivity(bytes32(uint256(123)), true);

        assertEq(module.lastActivity(), block.timestamp, "lastActivity should be updated");
        assertTrue(module.lastActivity() > oldActivity, "activity should increase");
    }

    // ============================================
    // Test 4: takeover before ready reverts
    // ============================================

    function test_Takeover_BeforeReadyReverts() public {
        // Warp to just before ready
        vm.warp(block.timestamp + DELAY - 1);

        uint256 currentTs = block.timestamp;
        uint256 readyAtTs = module.readyAt();

        vm.expectRevert(abi.encodeWithSelector(DeadManSwitchModule.NotReady.selector, currentTs, readyAtTs));
        vm.prank(heir);
        module.triggerTakeover();
    }

    // ============================================
    // Test 5: takeover after ready succeeds
    // ============================================

    function test_Takeover_AfterReadySucceeds() public {
        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Heir triggers takeover
        vm.prank(heir);
        module.triggerTakeover();

        // Verify heir is sole owner
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], heir, "heir should be the only owner");

        // Verify threshold is 1
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    // ============================================
    // Test 6: paused blocks takeover
    // ============================================

    function test_Takeover_WhenPausedReverts() public {
        // Pause the module via Safe
        safe.execAsSafe(address(module), abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(module.paused(), "should be paused");

        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Takeover should fail even though time has passed
        vm.prank(heir);
        vm.expectRevert(DeadManSwitchModule.Paused.selector);
        module.triggerTakeover();
    }

    // ============================================
    // Test 7: guard call failures do not revert Safe tx
    // ============================================

    function test_GuardFailureDoesNotRevertSafeTx() public {
        // Deploy a guard pointing to a reverting "module"
        RevertingModule revertingModule = new RevertingModule();
        DeadManSwitchGuard revertingGuard =
            new DeadManSwitchGuard(IDeadManSwitchModule(address(revertingModule)), address(safe));

        // Call checkAfterExecution as the Safe - should not revert even though module.notifyActivity reverts
        vm.prank(address(safe));
        revertingGuard.checkAfterExecution(bytes32(uint256(123)), true);

        // If we got here, the test passed - guard swallowed the revert
        assertTrue(true, "guard should not revert");
    }

    // ============================================
    // Test 8: heir is an existing owner — takeover should still work
    // ============================================

    function test_Takeover_HeirIsMiddleOwner() public {
        // Scenario: 2/3 multisig, heir is owner2.
        // owner1 and owner3 lose keys. owner2 (heir) can't reach threshold.
        // After delay, heir should be able to take over — NOT get stuck.
        safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", owner2));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner2);
        module.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner2, "heir (owner2) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_HeirIsFirstOwner() public {
        // Heir is owners[0] (head of linked list)
        safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", owner1));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner1);
        module.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner1, "heir (owner1) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_HeirIsLastOwner() public {
        // Heir is owners[2] (tail of linked list)
        safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", owner3));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner3);
        module.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner3, "heir (owner3) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_GuardIgnoresNonSafeCaller() public {
        uint256 activityBefore = module.lastActivity();
        vm.warp(block.timestamp + 1 hours);

        // Non-Safe caller: should silently return without updating activity
        vm.prank(address(0xBEEF));
        guard.checkAfterExecution(bytes32(uint256(999)), true);

        assertEq(module.lastActivity(), activityBefore, "activity should NOT be updated by non-Safe caller");
    }
}

/// @title DeadManSwitchExtraTests
/// @notice Additional edge case tests
contract DeadManSwitchExtraTests is Test {
    MockSafe public safe;
    DeadManSwitchModule public module;
    DeadManSwitchGuard public guard;

    address public owner1 = address(0x1001);
    address public heir = address(0x2001);
    uint256 public constant DELAY = 30 days;

    function setUp() public {
        // Deploy mock Safe with 1 owner
        safe = new MockSafe();
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        safe.setup(owners, 1);

        // Deploy module
        module = new DeadManSwitchModule(ISafe(address(safe)), heir, DELAY);

        // Enable module
        safe.execAsSafe(address(safe), abi.encodeWithSignature("enableModule(address)", address(module)));

        // Deploy and set guard
        guard = new DeadManSwitchGuard(IDeadManSwitchModule(address(module)), address(safe));
        safe.execAsSafe(address(safe), abi.encodeWithSignature("setGuard(address)", address(guard)));
        safe.execAsSafe(address(module), abi.encodeWithSignature("setGuard(address)", address(guard)));
    }

    // ============================================
    // Constructor validation tests
    // ============================================

    function test_Constructor_InvalidHeir() public {
        vm.expectRevert(DeadManSwitchModule.InvalidHeir.selector);
        new DeadManSwitchModule(ISafe(address(safe)), address(0), DELAY);
    }

    function test_Constructor_InvalidHeir_Sentinel() public {
        vm.expectRevert(DeadManSwitchModule.InvalidHeir.selector);
        new DeadManSwitchModule(ISafe(address(safe)), address(0x1), DELAY);
    }

    function test_Constructor_InvalidDelay() public {
        vm.expectRevert(DeadManSwitchModule.InvalidDelay.selector);
        new DeadManSwitchModule(ISafe(address(safe)), heir, 0);
    }

    function test_Constructor_InvalidDelay_TooLarge() public {
        vm.expectRevert(DeadManSwitchModule.InvalidDelay.selector);
        new DeadManSwitchModule(ISafe(address(safe)), heir, 366 days);
    }

    // ============================================
    // Access control tests
    // ============================================

    function test_SetHeir_OnlyBySafe() public {
        address newHeir = address(0x3001);

        // Non-Safe caller should revert
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotSafe.selector);
        module.setHeir(newHeir);

        // Safe can set heir
        safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", newHeir));
        assertEq(module.heir(), newHeir, "heir should be updated");
    }

    function test_SetHeir_InvalidHeir() public {
        // Safe cannot set zero address heir
        (bool success,) = safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", address(0)));
        assertFalse(success, "should fail for zero address");
    }

    function test_SetHeir_InvalidHeir_Sentinel() public {
        // Safe cannot set sentinel address as heir
        (bool success,) = safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", address(0x1)));
        assertFalse(success, "should fail for sentinel address");
    }

    function test_SetDelay_OnlyBySafe() public {
        uint256 newDelay = 60 days;

        // Non-Safe caller should revert
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotSafe.selector);
        module.setDelay(newDelay);

        // Safe can set delay
        safe.execAsSafe(address(module), abi.encodeWithSignature("setDelay(uint256)", newDelay));
        assertEq(module.delay(), newDelay, "delay should be updated");
    }

    function test_SetDelay_InvalidDelay() public {
        // Safe cannot set zero delay
        (bool success,) = safe.execAsSafe(address(module), abi.encodeWithSignature("setDelay(uint256)", 0));
        assertFalse(success, "should fail for zero delay");
    }

    function test_SetDelay_TooLarge() public {
        // Safe cannot set delay > MAX_DELAY
        (bool success,) = safe.execAsSafe(address(module), abi.encodeWithSignature("setDelay(uint256)", 366 days));
        assertFalse(success, "should fail for delay > MAX_DELAY");
    }

    function test_SetPaused_OnlyBySafe() public {
        // Non-Safe caller should revert
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotSafe.selector);
        module.setPaused(true);

        // Safe can pause
        safe.execAsSafe(address(module), abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(module.paused(), "should be paused");

        // Safe can unpause
        safe.execAsSafe(address(module), abi.encodeWithSignature("setPaused(bool)", false));
        assertFalse(module.paused(), "should be unpaused");
    }

    // ============================================
    // Ping tests
    // ============================================

    function test_Ping_OnlyBySafe() public {
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.NotSafe.selector);
        module.ping();
    }

    function test_Ping_ResetsActivity() public {
        uint256 initialActivity = module.lastActivity();

        // Warp forward
        vm.warp(block.timestamp + 10 days);

        // Ping via Safe
        safe.execAsSafe(address(module), abi.encodeWithSignature("ping()"));

        assertEq(module.lastActivity(), block.timestamp, "lastActivity should be current time");
        assertTrue(module.lastActivity() > initialActivity, "activity should have increased");
    }

    // ============================================
    // Takeover edge cases
    // ============================================

    function test_Takeover_OnlyHeir() public {
        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Non-heir should fail
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitchModule.InvalidHeir.selector);
        module.triggerTakeover();
    }

    function test_Takeover_HeirIsSoleOwner() public {
        // Heir is the only owner of the Safe — takeover is a no-op
        // but should succeed and pause the module
        safe.execAsSafe(address(module), abi.encodeWithSignature("setHeir(address)", owner1));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner1);
        module.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should still have exactly 1 owner");
        assertEq(owners[0], owner1, "owner1 should remain sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
        assertTrue(module.paused(), "module should be paused");
    }

    function test_Takeover_SingleOwner() public {
        // This tests the case where Safe has only 1 owner
        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Heir triggers takeover
        vm.prank(heir);
        module.triggerTakeover();

        // Verify heir is sole owner
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], heir, "heir should be the only owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_PausesModuleAfterwards() public {
        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        assertFalse(module.paused(), "should not be paused before takeover");

        // Heir triggers takeover
        vm.prank(heir);
        module.triggerTakeover();

        // Module should be paused after takeover
        assertTrue(module.paused(), "module should be paused after takeover");
    }

    // ============================================
    // View function tests
    // ============================================

    function test_ReadyAt() public view {
        assertEq(module.readyAt(), block.timestamp + DELAY, "readyAt should be lastActivity + delay");
    }

    function test_TimeRemaining() public {
        assertEq(module.timeRemaining(), DELAY, "timeRemaining should equal delay initially");

        // Warp halfway
        vm.warp(block.timestamp + DELAY / 2);
        assertEq(module.timeRemaining(), DELAY / 2, "timeRemaining should be half");

        // Warp past
        vm.warp(block.timestamp + DELAY);
        assertEq(module.timeRemaining(), 0, "timeRemaining should be 0 when ready");
    }

    // ============================================
    // Guard checkTransaction test
    // ============================================

    function test_Guard_CheckTransaction_DoesNotRevert() public {
        // checkTransaction should do nothing and not revert
        guard.checkTransaction(address(0), 0, "", 0, 0, 0, 0, address(0), payable(address(0)), "", address(0));
        // If we got here, it passed
    }
}
