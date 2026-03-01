// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

interface IDeadManSwitchModule {
    function notifyActivity(bytes32 txHash, bool success) external;
}

interface Guard {
    function checkTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures,
        address msgSender
    ) external;

    function checkAfterExecution(bytes32 txHash, bool success) external;
}

/// @title DeadManSwitchGuard
/// @notice Safe guard that records every execTransaction into the DeadManSwitchModule.
/// @dev Must be set as Safe guard (via Safe tx). Should never revert because it can brick the Safe.
contract DeadManSwitchGuard is Guard {
    IDeadManSwitchModule public immutable module;
    address public immutable safe;

    constructor(IDeadManSwitchModule _module, address _safe) {
        module = _module;
        safe = _safe;
    }

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
    ) external override {
        // Intentionally empty: no policy enforcement.
        // You COULD add policy logic here, but that’s separate from the dead-man switch feature.
    }

    function checkAfterExecution(bytes32 txHash, bool success) external override {
        // Only the Safe should call guard hooks. Silently ignore other callers
        // to prevent third parties from resetting the inactivity timer.
        if (msg.sender != safe) return;

        // Never revert: a reverting guard reverts the whole Safe tx.
        // Use low-level call to swallow failures.
        (bool ok, ) = address(module).call(
            abi.encodeWithSelector(IDeadManSwitchModule.notifyActivity.selector, txHash, success)
        );
        ok; // ignore
    }
}
