// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ISafe} from "../src/DeadManSwitch.sol";
import {DeadManSwitchFactory} from "../src/DeadManSwitchFactory.sol";

/// @title DeployDeadManSwitch
/// @notice Creates a DeadManSwitch clone for a specific Safe via the factory.
/// @dev After deployment, execute 2 Safe transactions:
///      1. safe.enableModule(dms)
///      2. safe.setGuard(dms)
contract DeployDeadManSwitch is Script {
    function run() external {
        address factoryAddress = vm.envAddress("FACTORY_ADDRESS");
        address safeAddress = vm.envAddress("SAFE_ADDRESS");
        address heirAddress = vm.envAddress("HEIR_ADDRESS");
        uint256 delaySeconds = vm.envUint("DELAY_SECONDS");

        DeadManSwitchFactory factory = DeadManSwitchFactory(factoryAddress);

        vm.startBroadcast();

        address clone = factory.create(ISafe(safeAddress), heirAddress, delaySeconds);

        vm.stopBroadcast();

        console.log("DeadManSwitch deployed at:", clone);
        console.log("");
        console.log("Next steps (execute as Safe transactions):");
        console.log("  1. safe.enableModule(%s)", clone);
        console.log("  2. safe.setGuard(%s)", clone);
    }
}
