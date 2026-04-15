// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/interfaces/IAgentRegistry.sol";

contract RegisterTestAgent is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address registry = 0xDd6D66924B43419F484aE981F174b803487AF25A;
        
        IAgentRegistry.ServiceDescriptor[] memory services = new IAgentRegistry.ServiceDescriptor[](1);
        services[0] = IAgentRegistry.ServiceDescriptor({
            serviceTypeHash: keccak256(bytes("code-review")),
            serviceType: "code-review",
            schemaURI: "",
            minPrice: 1000000,
            maxPrice: 100000000,
            avgCompletionTime: 300,
            metadataCID: ""
        });

        vm.startBroadcast(pk);
        IAgentRegistry(registry).registerAgent("https://test-agent.agirails.app", services);
        vm.stopBroadcast();
        
        console.log("Agent registered!");
    }
}
