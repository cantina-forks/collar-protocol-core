// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";

import { DeploymentUtils } from "../../../script/utils/deployment-exporter.s.sol";
import { ConfigHub } from "../../../src/ConfigHub.sol";
import { ArbitrumMainnetDeployer, BaseDeployer } from "../../../script/ArbitrumMainnetDeployer.sol";

abstract contract DeploymentLoader is Test, ArbitrumMainnetDeployer {
    ConfigHub public configHub;
    address public router;
    BaseDeployer.AssetPairContracts[] public deployedPairs;
    address owner;
    address user;
    address user2;
    address provider;
    // deployment checks
    uint forkId;
    bool forkSet;

    function setUp() public virtual {
        uint deployerPrivKey = vm.envUint("PRIVKEY_DEV_DEPLOYER");
        uint user1PrivKey = vm.envUint("PRIVKEY_DEV_TEST1");
        uint user2PrivKey = vm.envUint("PRIVKEY_DEV_TEST2");
        uint liquidityProviderPrivKey = vm.envUint("LIQUIDITY_PROVIDER_KEY");
        uint blockNumber = vm.envUint("BLOCK_NUMBER_ARBITRUM_MAINNET");

        owner = vm.addr(deployerPrivKey);
        user = vm.addr(user1PrivKey);
        user2 = vm.addr(user2PrivKey);
        provider = vm.addr(liquidityProviderPrivKey);

        vm.label(provider, "Liquidity Provider");
        vm.label(owner, "Owner");
        vm.label(user, "User");
        vm.label(user2, "User 2");
        if (!forkSet) {
            console.log("Setting up fork and deploying contracts");
            // this test suite needs to run independently so we load a fork here
            // if we are in development we want to fix the block to reduce the time it takes to run the tests
            bool shouldFixBlock = vm.envBool("FIX_BLOCK_ARBITRUM_MAINNET");
            if (shouldFixBlock) {
                vm.createSelectFork(vm.envString("ARBITRUM_MAINNET_RPC"), blockNumber);
            } else {
                forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC"));
                vm.selectFork(forkId);
            }

            // Deploy contracts
            vm.startPrank(owner);
            DeploymentResult memory result = deployAndSetupProtocol(owner);
            DeploymentUtils.exportDeployment(
                vm,
                "collar_protocol_fork_deployment",
                address(result.configHub),
                swapRouterAddress,
                result.assetPairContracts
            );
            vm.stopPrank();
            forkSet = true;
        } else {
            console.log("Fork already set, selecting fork");
            vm.selectFork(forkId);
        }
        (ConfigHub hub, BaseDeployer.AssetPairContracts[] memory pairs) = loadDeployment();
        configHub = hub;
        for (uint i = 0; i < pairs.length; i++) {
            deployedPairs.push(pairs[i]);
        }
        require(address(configHub) != address(0), "ConfigHub not deployed");
        require(deployedPairs.length > 0, "No pairs deployed");
    }

    function loadDeployment() internal view returns (ConfigHub, BaseDeployer.AssetPairContracts[] memory) {
        (address configHubAddress, BaseDeployer.AssetPairContracts[] memory pairs) =
            DeploymentUtils.getAll(vm, "collar_protocol_fork_deployment");

        return (ConfigHub(configHubAddress), pairs);
    }

    function getPairByAssets(address cashAsset, address underlying)
        internal
        view
        returns (BaseDeployer.AssetPairContracts memory pair)
    {
        for (uint i = 0; i < deployedPairs.length; i++) {
            if (
                address(deployedPairs[i].cashAsset) == cashAsset
                    && address(deployedPairs[i].underlying) == underlying
            ) {
                return deployedPairs[i];
            }
        }
    }
}
