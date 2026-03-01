// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// Minimal interface for Safe methods we use.
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation operation)
        external
        returns (bool success);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);
}

/// @title DeadManSwitch
/// @notice Safe module + guard that transfers Safe control to an heir after inactivity.
/// @dev Must be enabled as both a module and a guard on the Safe.
///      Deploy via DeadManSwitchFactory for cheap ERC-1167 clones.
contract DeadManSwitch {
    // ----------------------------
    // Errors
    // ----------------------------
    error NotSafe();
    error InvalidHeir();
    error InvalidDelay();
    error NotReady(uint256 nowTs, uint256 readyAt);
    error TakeoverFailed(bytes callData);
    error AlreadyInitialized();
    error Paused();
    error NoOwners();

    // ----------------------------
    // Events
    // ----------------------------
    event ActivityRecorded(uint256 timestamp, bytes32 txHash, bool success);
    event HeirChanged(address indexed oldHeir, address indexed newHeir);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event PausedChanged(bool paused);
    event TakeoverTriggered(address indexed heir, uint256 timestamp);

    // ----------------------------
    // Constants
    // ----------------------------
    address internal constant SENTINEL_OWNERS = address(0x1);
    uint256 public constant MAX_DELAY = 365 days;

    /// @dev Guard interface ID: checkTransaction.selector ^ checkAfterExecution.selector
    bytes4 private constant GUARD_INTERFACE_ID = 0xe6d7a83a;
    bytes4 private constant ERC165_INTERFACE_ID = 0x01ffc9a7;

    // ----------------------------
    // Storage
    // ----------------------------
    ISafe public safe;
    address public heir;
    uint256 public delay; // seconds
    uint256 public lastActivity;
    bool public paused;
    bool private _initialized;

    // ----------------------------
    // Initializer (replaces constructor for clone compatibility)
    // ----------------------------

    /// @notice Initialize the dead man's switch for a specific Safe.
    /// @param _safe The Gnosis Safe this instance will control.
    /// @param _heir Address that can trigger takeover after inactivity.
    /// @param _delaySeconds Seconds of inactivity before takeover is allowed (1 to MAX_DELAY).
    function initialize(ISafe _safe, address _heir, uint256 _delaySeconds) external {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        if (_heir == address(0) || _heir == SENTINEL_OWNERS) revert InvalidHeir();
        if (_delaySeconds == 0 || _delaySeconds > MAX_DELAY) revert InvalidDelay();

        safe = _safe;
        heir = _heir;
        delay = _delaySeconds;
        lastActivity = block.timestamp;
    }

    // ----------------------------
    // Modifiers
    // ----------------------------

    modifier onlySafe() {
        if (msg.sender != address(safe)) revert NotSafe();
        _;
    }

    // ----------------------------
    // Admin (only via Safe tx)
    // ----------------------------

    /// @notice Change the heir address.
    /// @param newHeir New heir. Cannot be address(0) or SENTINEL.
    function setHeir(address newHeir) external onlySafe {
        if (newHeir == address(0) || newHeir == SENTINEL_OWNERS) revert InvalidHeir();
        address old = heir;
        heir = newHeir;
        emit HeirChanged(old, newHeir);
    }

    /// @notice Change the inactivity delay.
    /// @param newDelaySeconds New delay in seconds (1 to MAX_DELAY).
    function setDelay(uint256 newDelaySeconds) external onlySafe {
        if (newDelaySeconds == 0 || newDelaySeconds > MAX_DELAY) revert InvalidDelay();
        uint256 old = delay;
        delay = newDelaySeconds;
        emit DelayChanged(old, newDelaySeconds);
    }

    /// @notice Pause or unpause the module. When paused, takeover is blocked.
    /// @param newPaused True to pause, false to unpause.
    function setPaused(bool newPaused) external onlySafe {
        paused = newPaused;
        emit PausedChanged(newPaused);
    }

    /// @notice Manual heartbeat that resets lastActivity.
    /// @dev Owners can call this via Safe tx if needed.
    function ping() external onlySafe {
        lastActivity = block.timestamp;
        emit ActivityRecorded(block.timestamp, bytes32(0), true);
    }

    // ----------------------------
    // Guard interface
    // ----------------------------

    /// @notice Pre-transaction hook. Intentionally empty — no policy enforcement.
    function checkTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata,
        address
    ) external {}

    /// @notice Post-transaction hook. Records activity after each Safe execTransaction.
    /// @dev Must NOT revert — a reverting guard bricks the Safe.
    ///      Silently ignores non-Safe callers to prevent third parties from resetting the timer.
    function checkAfterExecution(bytes32 txHash, bool success) external {
        if (msg.sender != address(safe)) return;
        lastActivity = block.timestamp;
        emit ActivityRecorded(block.timestamp, txHash, success);
    }

    // ----------------------------
    // ERC-165
    // ----------------------------

    /// @notice Returns true for Guard interface ID and ERC-165 interface ID.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == GUARD_INTERFACE_ID || interfaceId == ERC165_INTERFACE_ID;
    }

    // ----------------------------
    // Views
    // ----------------------------

    /// @notice Timestamp at which takeover becomes possible.
    function readyAt() public view returns (uint256) {
        return lastActivity + delay;
    }

    /// @notice Seconds remaining until takeover is possible. Returns 0 if already ready.
    function timeRemaining() external view returns (uint256) {
        uint256 ra = readyAt();
        if (block.timestamp >= ra) return 0;
        return ra - block.timestamp;
    }

    // ----------------------------
    // Takeover logic (heir-triggered)
    // ----------------------------

    /// @notice Transfers Safe control to the heir if inactivity >= delay.
    /// @dev Uses module privileges to call Safe's owner-management functions.
    function triggerTakeover() external {
        if (paused) revert Paused();
        if (msg.sender != heir) revert InvalidHeir();

        uint256 ra = readyAt();
        if (block.timestamp < ra) revert NotReady(block.timestamp, ra);

        address[] memory owners = safe.getOwners();
        if (owners.length < 1) revert NoOwners();

        // Check if heir is already in the owner list
        bool heirIsOwner = false;
        uint256 heirIndex = 0;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == heir) {
                heirIsOwner = true;
                heirIndex = i;
                break;
            }
        }

        if (heirIsOwner) {
            // Heir is already an owner — remove everyone else, keep heir.
            // Phase 1: Remove owners BEFORE heir in the linked list.
            // Each removal promotes the next owner to head, so prevOwner
            // is always SENTINEL.
            for (uint256 i = 0; i < heirIndex; i++) {
                _safeCall(
                    abi.encodeWithSignature("removeOwner(address,address,uint256)", SENTINEL_OWNERS, owners[i], 1)
                );
            }
            // Phase 2: Remove owners AFTER heir in the linked list.
            // Heir is now the head, so prevOwner is always heir.
            for (uint256 i = heirIndex + 1; i < owners.length; i++) {
                _safeCall(abi.encodeWithSignature("removeOwner(address,address,uint256)", heir, owners[i], 1));
            }
        } else {
            // Heir is NOT an owner — swap first owner with heir, then remove the rest.
            _safeCall(abi.encodeWithSignature("swapOwner(address,address,address)", SENTINEL_OWNERS, owners[0], heir));
            for (uint256 i = 1; i < owners.length; i++) {
                _safeCall(abi.encodeWithSignature("removeOwner(address,address,uint256)", heir, owners[i], 1));
            }
        }

        // Ensure threshold is 1
        _safeCall(abi.encodeWithSignature("changeThreshold(uint256)", 1));

        // Permanently pause to prevent reuse
        paused = true;

        emit TakeoverTriggered(heir, block.timestamp);
    }

    // ----------------------------
    // Internal helper
    // ----------------------------

    function _safeCall(bytes memory data) internal {
        bool ok = safe.execTransactionFromModule(address(safe), 0, data, ISafe.Operation.Call);
        if (!ok) revert TakeoverFailed(data);
    }
}
