// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {DeadManSwitch} from "../src/DeadManSwitch.sol";
import {DeadManSwitchFactory} from "../src/DeadManSwitchFactory.sol";

/// @title DeployFactory
/// @notice Deploys the DeadManSwitch implementation and factory (one-time per network).
contract DeployFactory is Script {
    function run() external {
        vm.startBroadcast();

        DeadManSwitch implementation = new DeadManSwitch();
        DeadManSwitchFactory factory = new DeadManSwitchFactory(address(implementation));

        vm.stopBroadcast();

        console.log("Implementation deployed at:", address(implementation));
        console.log("Factory deployed at:", address(factory));
    }
}
