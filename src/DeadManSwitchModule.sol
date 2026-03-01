// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

/// Minimal interface for Safe methods we use.
interface ISafe {
    enum Operation {
        Call,
        DelegateCall
    }

    // Module execution entrypoints (exist on Safe)
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    ) external returns (bool success);

    // Owner list helper (Safe inherits OwnerManager)
    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);
}

/// @title DeadManSwitchModule
/// @notice Safe module that can transfer Safe control to an heir after inactivity.
/// @dev Must be enabled as a module on the Safe. Best used together with DeadManSwitchGuard.
contract DeadManSwitchModule {
    // ----------------------------
    // Errors
    // ----------------------------
    error NotSafe();
    error NotGuard();
    error InvalidHeir();
    error InvalidDelay();
    error NotReady(uint256 nowTs, uint256 readyAt);
    error TakeoverFailed(bytes callData);
    error AlreadyInitialized();
    error Paused();
    error NoOwners();
    error HeirIsAlreadyOwner();

    // ----------------------------
    // Events
    // ----------------------------
    event ActivityRecorded(uint256 timestamp, bytes32 txHash, bool success);
    event HeirChanged(address indexed oldHeir, address indexed newHeir);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event PausedChanged(bool paused);
    event GuardChanged(address indexed oldGuard, address indexed newGuard);
    event TakeoverTriggered(address indexed heir, uint256 timestamp);

    // ----------------------------
    // Constants
    // ----------------------------
    address internal constant SENTINEL_OWNERS = address(0x1);

    // ----------------------------
    // Immutable / storage
    // ----------------------------
    ISafe public immutable safe;

    address public heir;
    uint256 public delay; // seconds

    /// @notice last time we observed Safe activity (via guard) or manual ping
    uint256 public lastActivity;

    /// @notice Safe guard allowed to call notifyActivity.
    address public guard;

    bool public paused;

    constructor(ISafe _safe, address _heir, uint256 _delaySeconds) {
        safe = _safe;

        if (_heir == address(0) || _heir == SENTINEL_OWNERS) revert InvalidHeir();
        if (_delaySeconds == 0) revert InvalidDelay();

        heir = _heir;
        delay = _delaySeconds;

        // Initialize activity at deployment time
        lastActivity = block.timestamp;
    }

    // ----------------------------
    // Modifiers
    // ----------------------------
    modifier onlySafe() {
        if (msg.sender != address(safe)) revert NotSafe();
        _;
    }

    modifier onlyGuard() {
        if (msg.sender != guard) revert NotGuard();
        _;
    }

    // ----------------------------
    // Admin (only via Safe tx)
    // ----------------------------

    /// @notice Set/replace the guard that is allowed to report activity.
    /// @dev Must be called by the Safe (i.e., via execTransaction).
    function setGuard(address newGuard) external onlySafe {
        address old = guard;
        guard = newGuard;
        emit GuardChanged(old, newGuard);
    }

    function setHeir(address newHeir) external onlySafe {
        if (newHeir == address(0) || newHeir == SENTINEL_OWNERS) revert InvalidHeir();
        address old = heir;
        heir = newHeir;
        emit HeirChanged(old, newHeir);
    }

    function setDelay(uint256 newDelaySeconds) external onlySafe {
        if (newDelaySeconds == 0) revert InvalidDelay();
        uint256 old = delay;
        delay = newDelaySeconds;
        emit DelayChanged(old, newDelaySeconds);
    }

    function setPaused(bool newPaused) external onlySafe {
        paused = newPaused;
        emit PausedChanged(newPaused);
    }

    /// @notice Manual heartbeat that resets lastActivity.
    /// @dev Owners can call this via Safe tx if needed (e.g., if guard is off, or for extra certainty).
    function ping() external onlySafe {
        lastActivity = block.timestamp;
        emit ActivityRecorded(block.timestamp, bytes32(0), true);
    }

    // ----------------------------
    // Activity hook (called by guard)
    // ----------------------------

    /// @notice Records activity after each Safe execTransaction (if wired via guard).
    /// @dev Must NOT revert; guards should never brick the Safe. Keep it simple.
    function notifyActivity(bytes32 txHash, bool success) external onlyGuard {
        // If paused, we still record activity by default (safer operationally).
        lastActivity = block.timestamp;
        emit ActivityRecorded(block.timestamp, txHash, success);
    }

    // ----------------------------
    // Views
    // ----------------------------

    function readyAt() public view returns (uint256) {
        return lastActivity + delay;
    }

    function timeRemaining() external view returns (uint256) {
        uint256 ra = readyAt();
        if (block.timestamp >= ra) return 0;
        return ra - block.timestamp;
    }

    // ----------------------------
    // Takeover logic (heir-triggered)
    // ----------------------------

    /// @notice Transfers Safe control to the heir if inactivity >= delay.
    /// @dev This uses module privileges to make the Safe call its own owner-management functions.
    function triggerTakeover() external {
        if (paused) revert Paused();
        if (msg.sender != heir) revert InvalidHeir();

        uint256 ra = readyAt();
        if (block.timestamp < ra) revert NotReady(block.timestamp, ra);

        // Step 0: read current owners and verify heir is not already one
        address[] memory owners = safe.getOwners();
        if (owners.length < 1) revert NoOwners();
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == heir) revert HeirIsAlreadyOwner();
        }

        // Step 1: swap first owner -> heir (heir becomes head)
        // Safe.swapOwner(prevOwner, oldOwner, newOwner)
        // We need prevOwner of owners[0]. In a Safe linked list, the "prev" of the head is SENTINEL (0x1).
        // OwnerManager uses SENTINEL_OWNERS = address(0x1).
        // So prevOwner = 0x000...001.
        _safeCall(
            abi.encodeWithSignature(
                "swapOwner(address,address,address)",
                address(0x0000000000000000000000000000000000000001),
                owners[0],
                heir
            )
        );

        // Step 2: remove remaining owners one-by-one.
        // After swap, the list begins: SENTINEL -> heir -> (old second owner) -> ...
        // So prevOwner is always heir for removing the next one.
        //
        // removeOwner(prevOwner, owner, _threshold)
        // We also set threshold to 1 during removals to keep invariants easy.
        for (uint256 i = 1; i < owners.length; i++) {
            _safeCall(
                abi.encodeWithSignature(
                    "removeOwner(address,address,uint256)",
                    heir,
                    owners[i],
                    1
                )
            );
        }

        // Step 3: ensure threshold is 1 (in case it wasn’t set by removals due to edge paths)
        _safeCall(
            abi.encodeWithSignature(
                "changeThreshold(uint256)",
                1
            )
        );

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
