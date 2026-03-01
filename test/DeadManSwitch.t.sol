// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeadManSwitch, ISafe} from "../src/DeadManSwitch.sol";
import {DeadManSwitchFactory} from "../src/DeadManSwitchFactory.sol";

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
    function swapOwner(address prevOwner, address oldOwner, address newOwner) external {
        require(msg.sender == address(this), "GS031");
        require(newOwner != address(0) && newOwner != SENTINEL_OWNERS, "GS203");
        require(ownerList[newOwner] == address(0), "GS204");
        require(ownerList[prevOwner] == oldOwner, "GS205");

        ownerList[newOwner] = ownerList[oldOwner];
        ownerList[prevOwner] = newOwner;
        ownerList[oldOwner] = address(0);

        emit RemovedOwner(oldOwner);
        emit AddedOwner(newOwner);
    }

    /// @notice Remove an owner and update threshold
    function removeOwner(address prevOwner, address owner, uint256 _threshold) external {
        require(msg.sender == address(this), "GS031");
        require(ownerCount - 1 >= _threshold, "GS201");
        require(ownerList[prevOwner] == owner, "GS205");
        require(owner != SENTINEL_OWNERS, "GS203");

        ownerList[prevOwner] = ownerList[owner];
        ownerList[owner] = address(0);
        ownerCount--;

        if (threshold != _threshold) {
            threshold = _threshold;
            emit ChangedThreshold(_threshold);
        }

        emit RemovedOwner(owner);
    }

    /// @notice Change the threshold
    function changeThreshold(uint256 _threshold) external {
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

/// @title DeadManSwitchTest
/// @notice Unit tests for DeadManSwitch (merged module+guard)
contract DeadManSwitchTest is Test {
    MockSafe public safe;
    DeadManSwitch public dms;
    DeadManSwitchFactory public factory;

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

        // Deploy via factory
        DeadManSwitch implementation = new DeadManSwitch();
        factory = new DeadManSwitchFactory(address(implementation));
        dms = DeadManSwitch(factory.create(ISafe(address(safe)), heir, DELAY));

        // Enable as module on Safe
        safe.execAsSafe(address(safe), abi.encodeWithSignature("enableModule(address)", address(dms)));

        // Set as guard on Safe
        safe.execAsSafe(address(safe), abi.encodeWithSignature("setGuard(address)", address(dms)));
    }

    // ============================================
    // Deployment + Init
    // ============================================

    function test_DeploymentAndInit() public view {
        assertEq(address(dms.safe()), address(safe), "safe mismatch");
        assertEq(dms.heir(), heir, "heir mismatch");
        assertEq(dms.delay(), DELAY, "delay mismatch");
        assertEq(dms.lastActivity(), block.timestamp, "lastActivity should be deployment time");
        assertEq(dms.paused(), false, "should not be paused");

        // Check Safe state
        assertEq(safe.threshold(), 2, "threshold mismatch");
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 3, "owner count mismatch");
        assertEq(owners[0], owner1, "owner1 mismatch");
        assertEq(owners[1], owner2, "owner2 mismatch");
        assertEq(owners[2], owner3, "owner3 mismatch");
    }

    // ============================================
    // checkAfterExecution (replaces notifyActivity + guard tests)
    // ============================================

    function test_CheckAfterExecution_UpdatesActivity() public {
        uint256 oldActivity = dms.lastActivity();
        vm.warp(block.timestamp + 1 hours);

        // Safe calls checkAfterExecution — should update lastActivity
        vm.prank(address(safe));
        dms.checkAfterExecution(bytes32(uint256(123)), true);

        assertEq(dms.lastActivity(), block.timestamp, "lastActivity should be updated");
        assertTrue(dms.lastActivity() > oldActivity, "activity should increase");
    }

    function test_CheckAfterExecution_IgnoresNonSafe() public {
        uint256 activityBefore = dms.lastActivity();
        vm.warp(block.timestamp + 1 hours);

        // Non-Safe caller: should silently return without updating activity
        vm.prank(address(0xBEEF));
        dms.checkAfterExecution(bytes32(uint256(999)), true);

        assertEq(dms.lastActivity(), activityBefore, "activity should NOT be updated by non-Safe caller");
    }

    // ============================================
    // checkTransaction (no-op)
    // ============================================

    function test_CheckTransaction_NoOp() public {
        // checkTransaction should do nothing and not revert
        dms.checkTransaction(address(0), 0, "", 0, 0, 0, 0, address(0), payable(address(0)), "", address(0));
    }

    // ============================================
    // supportsInterface
    // ============================================

    function test_SupportsInterface() public view {
        assertTrue(dms.supportsInterface(0xe6d7a83a), "should support Guard interface");
        assertTrue(dms.supportsInterface(0x01ffc9a7), "should support ERC-165");
        assertFalse(dms.supportsInterface(0xdeadbeef), "should not support random interface");
    }

    // ============================================
    // Takeover timing
    // ============================================

    function test_Takeover_BeforeReadyReverts() public {
        vm.warp(block.timestamp + DELAY - 1);

        uint256 currentTs = block.timestamp;
        uint256 readyAtTs = dms.readyAt();

        vm.expectRevert(abi.encodeWithSelector(DeadManSwitch.NotReady.selector, currentTs, readyAtTs));
        vm.prank(heir);
        dms.triggerTakeover();
    }

    function test_Takeover_AfterReadySucceeds() public {
        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(heir);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], heir, "heir should be the only owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    // ============================================
    // Pause
    // ============================================

    function test_Takeover_WhenPausedReverts() public {
        safe.execAsSafe(address(dms), abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(dms.paused(), "should be paused");

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(heir);
        vm.expectRevert(DeadManSwitch.Paused.selector);
        dms.triggerTakeover();
    }

    // ============================================
    // Heir-is-owner variants
    // ============================================

    function test_Takeover_HeirIsMiddleOwner() public {
        safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", owner2));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner2);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner2, "heir (owner2) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_HeirIsFirstOwner() public {
        safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", owner1));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner1);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner1, "heir (owner1) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_HeirIsLastOwner() public {
        safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", owner3));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner3);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], owner3, "heir (owner3) should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }
}

/// @title DeadManSwitchEdgeCaseTest
/// @notice Additional edge case tests with 1-owner Safe
contract DeadManSwitchEdgeCaseTest is Test {
    MockSafe public safe;
    DeadManSwitch public dms;
    DeadManSwitchFactory public factory;

    address public owner1 = address(0x1001);
    address public heir = address(0x2001);
    uint256 public constant DELAY = 30 days;

    function setUp() public {
        // Deploy mock Safe with 1 owner
        safe = new MockSafe();
        address[] memory owners = new address[](1);
        owners[0] = owner1;
        safe.setup(owners, 1);

        // Deploy via factory
        DeadManSwitch implementation = new DeadManSwitch();
        factory = new DeadManSwitchFactory(address(implementation));
        dms = DeadManSwitch(factory.create(ISafe(address(safe)), heir, DELAY));

        // Enable as module + set as guard
        safe.execAsSafe(address(safe), abi.encodeWithSignature("enableModule(address)", address(dms)));
        safe.execAsSafe(address(safe), abi.encodeWithSignature("setGuard(address)", address(dms)));
    }

    // ============================================
    // Initialize validation tests
    // ============================================

    function test_Initialize_InvalidHeir() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        vm.expectRevert(DeadManSwitch.InvalidHeir.selector);
        f.create(ISafe(address(safe)), address(0), DELAY);
    }

    function test_Initialize_InvalidHeir_Sentinel() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        vm.expectRevert(DeadManSwitch.InvalidHeir.selector);
        f.create(ISafe(address(safe)), address(0x1), DELAY);
    }

    function test_Initialize_InvalidDelay() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        vm.expectRevert(DeadManSwitch.InvalidDelay.selector);
        f.create(ISafe(address(safe)), heir, 0);
    }

    function test_Initialize_InvalidDelay_TooLarge() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        vm.expectRevert(DeadManSwitch.InvalidDelay.selector);
        f.create(ISafe(address(safe)), heir, 366 days);
    }

    function test_Initialize_CannotReinitialize() public {
        vm.expectRevert(DeadManSwitch.AlreadyInitialized.selector);
        dms.initialize(ISafe(address(safe)), heir, DELAY);
    }

    // ============================================
    // Factory tests
    // ============================================

    function test_Factory_Create() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        address clone = f.create(ISafe(address(safe)), heir, DELAY);

        DeadManSwitch instance = DeadManSwitch(clone);
        assertEq(address(instance.safe()), address(safe), "safe mismatch");
        assertEq(instance.heir(), heir, "heir mismatch");
        assertEq(instance.delay(), DELAY, "delay mismatch");
        assertEq(instance.lastActivity(), block.timestamp, "lastActivity mismatch");
    }

    function test_Factory_Predict() public {
        DeadManSwitch impl = new DeadManSwitch();
        DeadManSwitchFactory f = new DeadManSwitchFactory(address(impl));

        address predicted = f.predict(ISafe(address(safe)), heir, DELAY);
        address actual = f.create(ISafe(address(safe)), heir, DELAY);

        assertEq(predicted, actual, "predicted address should match actual");
    }

    // ============================================
    // Access control tests
    // ============================================

    function test_SetHeir_OnlyBySafe() public {
        address newHeir = address(0x3001);

        vm.prank(owner1);
        vm.expectRevert(DeadManSwitch.NotSafe.selector);
        dms.setHeir(newHeir);

        safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", newHeir));
        assertEq(dms.heir(), newHeir, "heir should be updated");
    }

    function test_SetHeir_InvalidHeir() public {
        (bool success,) = safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", address(0)));
        assertFalse(success, "should fail for zero address");
    }

    function test_SetHeir_InvalidHeir_Sentinel() public {
        (bool success,) = safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", address(0x1)));
        assertFalse(success, "should fail for sentinel address");
    }

    function test_SetDelay_OnlyBySafe() public {
        uint256 newDelay = 60 days;

        vm.prank(owner1);
        vm.expectRevert(DeadManSwitch.NotSafe.selector);
        dms.setDelay(newDelay);

        safe.execAsSafe(address(dms), abi.encodeWithSignature("setDelay(uint256)", newDelay));
        assertEq(dms.delay(), newDelay, "delay should be updated");
    }

    function test_SetDelay_InvalidDelay() public {
        (bool success,) = safe.execAsSafe(address(dms), abi.encodeWithSignature("setDelay(uint256)", 0));
        assertFalse(success, "should fail for zero delay");
    }

    function test_SetDelay_TooLarge() public {
        (bool success,) = safe.execAsSafe(address(dms), abi.encodeWithSignature("setDelay(uint256)", 366 days));
        assertFalse(success, "should fail for delay > MAX_DELAY");
    }

    function test_SetPaused_OnlyBySafe() public {
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitch.NotSafe.selector);
        dms.setPaused(true);

        safe.execAsSafe(address(dms), abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(dms.paused(), "should be paused");

        safe.execAsSafe(address(dms), abi.encodeWithSignature("setPaused(bool)", false));
        assertFalse(dms.paused(), "should be unpaused");
    }

    // ============================================
    // Ping tests
    // ============================================

    function test_Ping_OnlyBySafe() public {
        vm.prank(owner1);
        vm.expectRevert(DeadManSwitch.NotSafe.selector);
        dms.ping();
    }

    function test_Ping_ResetsActivity() public {
        uint256 initialActivity = dms.lastActivity();

        vm.warp(block.timestamp + 10 days);

        safe.execAsSafe(address(dms), abi.encodeWithSignature("ping()"));

        assertEq(dms.lastActivity(), block.timestamp, "lastActivity should be current time");
        assertTrue(dms.lastActivity() > initialActivity, "activity should have increased");
    }

    // ============================================
    // Takeover edge cases
    // ============================================

    function test_Takeover_OnlyHeir() public {
        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner1);
        vm.expectRevert(DeadManSwitch.InvalidHeir.selector);
        dms.triggerTakeover();
    }

    function test_Takeover_HeirIsSoleOwner() public {
        safe.execAsSafe(address(dms), abi.encodeWithSignature("setHeir(address)", owner1));

        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(owner1);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should still have exactly 1 owner");
        assertEq(owners[0], owner1, "owner1 should remain sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
        assertTrue(dms.paused(), "module should be paused");
    }

    function test_Takeover_SingleOwner() public {
        vm.warp(block.timestamp + DELAY + 1);

        vm.prank(heir);
        dms.triggerTakeover();

        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], heir, "heir should be the only owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
    }

    function test_Takeover_PausesModuleAfterwards() public {
        vm.warp(block.timestamp + DELAY + 1);

        assertFalse(dms.paused(), "should not be paused before takeover");

        vm.prank(heir);
        dms.triggerTakeover();

        assertTrue(dms.paused(), "module should be paused after takeover");
    }

    // ============================================
    // View function tests
    // ============================================

    function test_ReadyAt() public view {
        assertEq(dms.readyAt(), block.timestamp + DELAY, "readyAt should be lastActivity + delay");
    }

    function test_TimeRemaining() public {
        assertEq(dms.timeRemaining(), DELAY, "timeRemaining should equal delay initially");

        vm.warp(block.timestamp + DELAY / 2);
        assertEq(dms.timeRemaining(), DELAY / 2, "timeRemaining should be half");

        vm.warp(block.timestamp + DELAY);
        assertEq(dms.timeRemaining(), 0, "timeRemaining should be 0 when ready");
    }
}
