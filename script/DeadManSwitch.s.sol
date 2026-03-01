// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeadManSwitchModule, ISafe} from "../src/DeadManSwitchModule.sol";
import {DeadManSwitchGuard, IDeadManSwitchModule} from "../src/DeadManSwitchGuard.sol";

/// @title DeadManSwitchScript
/// @notice Deploys DeadManSwitchModule and DeadManSwitchGuard.
/// @dev After deployment, you still need to execute 3 Safe transactions:
///      1. safe.enableModule(module)
///      2. safe.setGuard(guard)
///      3. module.setGuard(guard)
contract DeadManSwitchScript is Script {
    function run() external {
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address heirAddress = vm.envAddress("HEIR_ADDRESS");
        uint256 delaySeconds = vm.envUint("DELAY_SECONDS");

        vm.startBroadcast();

        DeadManSwitchModule module = new DeadManSwitchModule(ISafe(safeAddress), heirAddress, delaySeconds);
        DeadManSwitchGuard guard = new DeadManSwitchGuard(IDeadManSwitchModule(address(module)), safeAddress);

        vm.stopBroadcast();

        console.log("Module deployed at:", address(module));
        console.log("Guard deployed at:", address(guard));
        console.log("");
        console.log("Next steps (execute as Safe transactions):");
        console.log("  1. safe.enableModule(%s)", address(module));
        console.log("  2. safe.setGuard(%s)", address(guard));
        console.log("  3. module.setGuard(%s)", address(guard));
    }
}
