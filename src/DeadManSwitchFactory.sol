// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {DeadManSwitch, ISafe} from "./DeadManSwitch.sol";

/// @title DeadManSwitchFactory
/// @notice Deploys ERC-1167 minimal proxy clones of DeadManSwitch.
/// @dev Deploy one implementation contract, then use this factory to create
///      cheap per-Safe clones (~45 bytes each).
contract DeadManSwitchFactory {
    // ----------------------------
    // Events
    // ----------------------------
    event DeadManSwitchCreated(address indexed clone, address indexed safe, address indexed heir, uint256 delay);

    // ----------------------------
    // State
    // ----------------------------
    address public immutable implementation;

    // ----------------------------
    // Constructor
    // ----------------------------

    /// @param _implementation Address of the DeadManSwitch implementation contract.
    constructor(address _implementation) {
        implementation = _implementation;
    }

    // ----------------------------
    // Factory
    // ----------------------------

    /// @notice Deploy a new DeadManSwitch clone for a Safe.
    /// @param _safe The Gnosis Safe to protect.
    /// @param _heir Address that can trigger takeover after inactivity.
    /// @param _delaySeconds Seconds of inactivity before takeover is allowed.
    /// @return clone The address of the deployed clone.
    function create(ISafe _safe, address _heir, uint256 _delaySeconds) external returns (address clone) {
        clone = _clone(implementation, _salt(_safe, _heir, _delaySeconds));
        DeadManSwitch(clone).initialize(_safe, _heir, _delaySeconds);
        emit DeadManSwitchCreated(clone, address(_safe), _heir, _delaySeconds);
    }

    /// @notice Predict the deterministic address of a clone before deployment.
    /// @param _safe The Gnosis Safe.
    /// @param _heir The heir address.
    /// @param _delaySeconds The inactivity delay.
    /// @return The address the clone will be deployed to.
    function predict(ISafe _safe, address _heir, uint256 _delaySeconds) external view returns (address) {
        return _predictAddress(implementation, _salt(_safe, _heir, _delaySeconds));
    }

    // ----------------------------
    // Internal: ERC-1167 Minimal Proxy
    // ----------------------------

    function _salt(ISafe _safe, address _heir, uint256 _delaySeconds) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(address(_safe), _heir, _delaySeconds));
    }

    function _clone(address impl, bytes32 salt) internal returns (address instance) {
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        require(instance != address(0), "clone failed");
    }

    function _predictAddress(address impl, bytes32 salt) internal view returns (address predicted) {
        bytes32 creationCodeHash;
        /// @solidity memory-safe-assembly
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(96, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            creationCodeHash := keccak256(ptr, 0x37)
        }
        predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, creationCodeHash)))));
    }
}
