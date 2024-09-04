// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.22;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import { ConfigHub } from "../../src/ConfigHub.sol";
import { ProviderPositionNFT } from "../../src/ProviderPositionNFT.sol";
import { CollarTakerNFT } from "../../src/CollarTakerNFT.sol";
import { Loans } from "../../src/Loans.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Rolls } from "../../src/Rolls.sol";
import { DeploymentUtils } from "../utils/deployment-exporter.s.sol";
import { IV3SwapRouter } from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import { CollarOwnedERC20 } from "../../test/utils/CollarOwnedERC20.sol";
import { INonfungiblePositionManager } from
    "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import { IUniswapV3Factory } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import { IPeripheryImmutableState } from
    "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import { OracleUniV3TWAP } from "../../src/OracleUniV3TWAP.sol";
import { DeploymentHelper } from "../deployment-helper.sol";
import { SetupHelper } from "../setup-helper.sol";
import { WalletLoader } from "../wallet-loader.s.sol";
import { UniswapNewPoolHelper } from "../../test/utils/UniswapNewPoolHelper.sol";

contract DeployContractsArbitrumSepolia is
    Script,
    DeploymentUtils,
    UniswapNewPoolHelper,
    SetupHelper,
    DeploymentHelper,
    WalletLoader
{
    uint chainId = 421_614; // Arbitrum Sepolia chain ID
    IV3SwapRouter constant SWAP_ROUTER = IV3SwapRouter(0x101F443B4d1b059569D643917553c771E1b9663E);
    INonfungiblePositionManager constant POSITION_MANAGER =
        INonfungiblePositionManager(0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65);
    uint duration = 300;
    uint ltv = 9000;
    uint32 twapWindow = 15 minutes;
    uint amountToProvideToPool = 10_000_000 ether;

    // Set these to non-zero addresses if you want to use existing tokens
    address public cashAssetAddress = address(0x5D01F1E59C188a2A9Afc376cF6627dd5F28DC28F);
    address public collateralAssetAddress = address(0x9A6E1a5f94De0aD8ca15b55eA0d39bEaEc579434);

    function run() external {
        require(chainId == block.chainid, "chainId does not match the chainId in config");
        (address deployer,,,) = setup();

        vm.startBroadcast(deployer);

        ConfigHub configHub = deployConfigHub(deployer);

        (cashAssetAddress, collateralAssetAddress) = _setupAssets();

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = collateralAssetAddress;
        address[] memory cashAssets = new address[](1);
        cashAssets[0] = cashAssetAddress;

        setupConfigHub(
            configHub,
            HubParams({
                cashAssets: cashAssets,
                collateralAssets: collateralAssets,
                minLTV: ltv,
                maxLTV: ltv,
                minDuration: duration,
                maxDuration: duration
            })
        );

        _setupUniswapPool(cashAssetAddress, collateralAssetAddress);

        uint[] memory durations = new uint[](1);
        durations[0] = duration;
        uint[] memory ltvs = new uint[](1);
        ltvs[0] = ltv;
        uint24 oracleFeeTier = 3000;
        uint24 swapFeeTier = 3000;

        PairConfig memory pairConfig = PairConfig({
            name: "COLLATERAL/CASH",
            durations: durations,
            ltvs: ltvs,
            cashAsset: IERC20(cashAssetAddress),
            collateralAsset: IERC20(collateralAssetAddress),
            oracleFeeTier: oracleFeeTier,
            swapFeeTier: swapFeeTier,
            twapWindow: twapWindow,
            swapRouter: address(SWAP_ROUTER)
        });

        AssetPairContracts memory contracts = deployContractPair(configHub, pairConfig, deployer);

        setupContractPair(configHub, contracts);

        vm.stopBroadcast();

        AssetPairContracts[] memory contractsArray = new AssetPairContracts[](1);
        contractsArray[0] = contracts;
        exportDeployment(
            "arbitrum_sepolia_collar_protocol_deployment",
            address(configHub),
            address(SWAP_ROUTER),
            contractsArray
        );

        console.log("\nDeployment completed successfully");
    }

    function _setupAssets() internal returns (address cash, address collateral) {
        if (cashAssetAddress == address(0) || collateralAssetAddress == address(0)) {
            console.log("Deploying new token contracts");
            (cash, collateral) = deployTokens();
            console.log("Deployed Cash Asset: ", cash);
            console.log("Deployed Collateral Asset: ", collateral);
        } else {
            console.log("Using existing token contracts");
            cash = cashAssetAddress;
            collateral = collateralAssetAddress;
            console.log("Cash Asset: ", cash);
            console.log("Collateral Asset: ", collateral);
        }
    }

    function _setupUniswapPool(address cashAsset, address collateralAsset)
        internal
        returns (address poolAddress)
    {
        IUniswapV3Factory factory =
            IUniswapV3Factory(IPeripheryImmutableState(address(SWAP_ROUTER)).factory());
        poolAddress = factory.getPool(cashAsset, collateralAsset, 3000);

        if (poolAddress == address(0)) {
            console.log("Creating new Uniswap V3 pool");
            PoolParams memory params = PoolParams({
                token1: cashAsset,
                token2: collateralAsset,
                router: address(SWAP_ROUTER),
                positionManager: address(POSITION_MANAGER),
                feeTier: 3000,
                cardinality: 300,
                initialAmount: amountToProvideToPool,
                tickSpacing: 60
            });
            poolAddress = setupNewPool(params);
        }

        console.log("Uniswap V3 Pool: ", poolAddress);
    }
}
