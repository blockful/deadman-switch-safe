// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DeadManSwitch, ISafe} from "../src/DeadManSwitch.sol";
import {DeadManSwitchFactory} from "../src/DeadManSwitchFactory.sol";

/// @title Minimal Safe interfaces for fork testing
interface IGnosisSafe {
    enum Operation {
        Call,
        DelegateCall
    }

    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);

    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isOwner(address owner) external view returns (bool);
    function isModuleEnabled(address module) external view returns (bool);
    function nonce() external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
}

interface IGnosisSafeProxyFactory {
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

/// @title DeadManSwitchForkTest
/// @notice Fork-based integration tests against real Gnosis Safe contracts
contract DeadManSwitchForkTest is Test {
    // Mainnet addresses
    address constant SAFE_SINGLETON = 0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552; // Safe v1.3.0
    address constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;

    IGnosisSafe public safe;
    DeadManSwitch public dms;
    DeadManSwitchFactory public factory;

    // Test accounts (we use vm.addr to generate from private keys for signing)
    uint256 constant OWNER1_PK = 0x1;
    uint256 constant OWNER2_PK = 0x2;
    uint256 constant OWNER3_PK = 0x3;
    uint256 constant HEIR_PK = 0x4;

    address public owner1;
    address public owner2;
    address public owner3;
    address public heir;

    uint256 public constant DELAY = 30 days;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"));

        // Generate addresses from private keys
        owner1 = vm.addr(OWNER1_PK);
        owner2 = vm.addr(OWNER2_PK);
        owner3 = vm.addr(OWNER3_PK);
        heir = vm.addr(HEIR_PK);

        // Fund accounts
        vm.deal(owner1, 10 ether);
        vm.deal(owner2, 10 ether);
        vm.deal(owner3, 10 ether);
        vm.deal(heir, 10 ether);

        // Deploy a fresh Safe
        safe = _deploySafe();

        // Deploy via factory
        DeadManSwitch implementation = new DeadManSwitch();
        factory = new DeadManSwitchFactory(address(implementation));
        dms = DeadManSwitch(factory.create(ISafe(address(safe)), heir, DELAY));

        // Enable as module on Safe (requires Safe tx with signatures)
        _execSafeTx(address(safe), 0, abi.encodeWithSignature("enableModule(address)", address(dms)));

        // Set as guard on Safe (this calls supportsInterface on the real Safe)
        _execSafeTx(address(safe), 0, abi.encodeWithSignature("setGuard(address)", address(dms)));
    }

    // ============================================
    // Integration Test: Full End-to-End Flow
    // ============================================

    function test_Fork_FullIntegrationFlow() public {
        // Verify initial state
        assertEq(safe.getOwners().length, 3, "should have 3 owners");
        assertEq(safe.getThreshold(), 2, "threshold should be 2");
        assertTrue(safe.isModuleEnabled(address(dms)), "module should be enabled");

        // Step 2: Verify takeover fails before delay
        vm.warp(block.timestamp + DELAY - 1);

        vm.prank(heir);
        vm.expectRevert(); // NotReady
        dms.triggerTakeover();

        // Step 3: Verify takeover succeeds after delay
        vm.warp(block.timestamp + 2); // Now past delay

        vm.prank(heir);
        dms.triggerTakeover();

        // Step 4: Verify heir is sole owner
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have exactly 1 owner");
        assertEq(owners[0], heir, "heir should be sole owner");
        assertEq(safe.getThreshold(), 1, "threshold should be 1");
        assertTrue(safe.isOwner(heir), "heir should be owner");
        assertFalse(safe.isOwner(owner1), "owner1 should not be owner");
        assertFalse(safe.isOwner(owner2), "owner2 should not be owner");
        assertFalse(safe.isOwner(owner3), "owner3 should not be owner");
    }

    // ============================================
    // Integration Test: Activity Reset via Safe Tx
    // ============================================

    function test_Fork_ActivityResetOnSafeTx() public {
        uint256 initialActivity = dms.lastActivity();

        // Warp forward
        vm.warp(block.timestamp + 10 days);

        // Execute a Safe tx — guard (dms) checkAfterExecution resets activity
        _execSafeTx(owner1, 0, "");

        // Activity should be reset to current time
        assertEq(dms.lastActivity(), block.timestamp, "activity should be current time");
        assertTrue(dms.lastActivity() > initialActivity, "activity should have increased");

        // Takeover should now require full delay from this point
        assertEq(dms.readyAt(), block.timestamp + DELAY, "readyAt should be reset");
    }

    // ============================================
    // Integration Test: Ping Resets Activity
    // ============================================

    function test_Fork_PingResetsActivity() public {
        uint256 initialActivity = dms.lastActivity();

        // Warp forward (but not past delay)
        vm.warp(block.timestamp + 15 days);

        // Ping via Safe tx
        _execSafeTx(address(dms), 0, abi.encodeWithSignature("ping()"));

        // Activity should be reset
        assertEq(dms.lastActivity(), block.timestamp, "activity should be current time");
        assertTrue(dms.lastActivity() > initialActivity, "activity should have increased");
    }

    // ============================================
    // Integration Test: Pause Blocks Takeover
    // ============================================

    function test_Fork_PauseBlocksTakeover() public {
        // Pause via Safe tx
        _execSafeTx(address(dms), 0, abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(dms.paused(), "should be paused");

        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Takeover should fail
        vm.prank(heir);
        vm.expectRevert(DeadManSwitch.Paused.selector);
        dms.triggerTakeover();
    }

    // ============================================
    // Integration Test: Change Heir
    // ============================================

    function test_Fork_ChangeHeir() public {
        address newHeir = address(0x9999);

        // Change heir via Safe tx
        _execSafeTx(address(dms), 0, abi.encodeWithSignature("setHeir(address)", newHeir));
        assertEq(dms.heir(), newHeir, "heir should be changed");

        // Warp past delay
        vm.warp(block.timestamp + DELAY + 1);

        // Old heir cannot trigger takeover
        vm.prank(heir);
        vm.expectRevert(DeadManSwitch.InvalidHeir.selector);
        dms.triggerTakeover();

        // New heir can trigger takeover
        vm.prank(newHeir);
        dms.triggerTakeover();

        // Verify new heir is sole owner
        address[] memory owners = safe.getOwners();
        assertEq(owners.length, 1, "should have 1 owner");
        assertEq(owners[0], newHeir, "new heir should be sole owner");
    }

    // ============================================
    // Helper: Deploy Safe
    // ============================================

    function _deploySafe() internal returns (IGnosisSafe) {
        address[] memory owners = new address[](3);
        owners[0] = owner1;
        owners[1] = owner2;
        owners[2] = owner3;

        bytes memory initializer = abi.encodeWithSelector(
            IGnosisSafe.setup.selector,
            owners,
            2, // threshold
            address(0), // to
            "", // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            0, // payment
            payable(address(0)) // paymentReceiver
        );

        address proxy = IGnosisSafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(
            SAFE_SINGLETON,
            initializer,
            block.timestamp // salt nonce
        );

        // Fund the Safe
        vm.deal(proxy, 10 ether);

        return IGnosisSafe(proxy);
    }

    // ============================================
    // Helper: Execute Safe Transaction
    // ============================================

    function _execSafeTx(address to, uint256 value, bytes memory data) internal {
        // Build transaction hash
        bytes32 txHash = safe.getTransactionHash(
            to,
            value,
            data,
            IGnosisSafe.Operation.Call,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            safe.nonce()
        );

        // Sign with owner1 and owner2 (threshold is 2)
        // Safe expects signatures in order of owner address (ascending)
        bytes memory signatures;
        if (owner1 < owner2) {
            signatures = _buildSignatures(txHash, OWNER1_PK, OWNER2_PK);
        } else {
            signatures = _buildSignatures(txHash, OWNER2_PK, OWNER1_PK);
        }

        // Execute
        safe.execTransaction(
            to,
            value,
            data,
            IGnosisSafe.Operation.Call,
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );
    }

    // ============================================
    // Helper: Build Signatures
    // ============================================

    function _buildSignatures(bytes32 txHash, uint256 pk1, uint256 pk2) internal pure returns (bytes memory) {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(pk1, txHash);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(pk2, txHash);

        return abi.encodePacked(r1, s1, v1, r2, s2, v2);
    }
}
