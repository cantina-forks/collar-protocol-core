// SPDX-License-Identifier: MIT

/*
 * Copyright (c) 2023 Collar Networks, Inc. <hello@collarprotocolentAsset.xyz>
 * All rights reserved. No warranty, explicit or implicit, provided.
 */

// how does this contract work exactly? let's ask chatGPT
// https://chat.openai.com/share/fcdbd3fa-5aa3-42ef-8c61-cbcfe7f09524

pragma solidity ^0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SwapRouter } from "@uni-v3-periphery/SwapRouter.sol";
import { ISwapRouter } from "@uni-v3-periphery/interfaces/ISwapRouter.sol";
import { ICollarEngine, ICollarEngineErrors } from "../../protocol/interfaces/IEngine.sol";
import { ICollarVaultManager } from "../interfaces/ICollarVaultManager.sol";
import { CollarLiquidityPool } from "../../liquidity/implementations/CollarLiquidityPool.sol";
import { ICollarLiquidityPoolManager } from "../../protocol/interfaces/ICollarLiquidityPoolManager.sol";
import { CollarVaultState, CollarVaultManagerErrors, CollarVaultManagerEvents, CollarVaultConstants } from "../../vaults/interfaces/CollarLibs.sol";
import { CollarVaultLens } from "./CollarVaultLens.sol";
import { TickCalculations } from "../../liquidity/implementations/TickCalculations.sol";

contract CollarVaultManager is ICollarVaultManager, ICollarEngineErrors, CollarVaultLens {
    constructor(address _engine, address _owner) ICollarVaultManager(_engine) {
        user = _owner;
     }

    function openVault(
        CollarVaultState.AssetSpecifiers calldata assetSpecifiers,
        CollarVaultState.CollarOpts calldata collarOpts,
        CollarVaultState.LiquidityOpts calldata liquidityOpts
    ) external override returns (bytes32 vaultUUID) {
        // basic validations
        validateAssets(assetSpecifiers);
        validateOpts(collarOpts);
        validateLiquidity(liquidityOpts);

        // attempt to lock the liquidity (to pay out max call strike)
        CollarLiquidityPool(liquidityOpts.liquidityPool).lockLiquidityAtTicks(liquidityOpts.totalLiquidity, liquidityOpts.ratios, liquidityOpts.ticks);

        // swap entire amount of collateral for cash
        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: assetSpecifiers.collateralAsset,
            tokenOut: assetSpecifiers.cashAsset,
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: assetSpecifiers.collateralAmount,
            amountOutMinimum: assetSpecifiers.cashAmount,
            sqrtPriceLimitX96: 0
        });
    
        IERC20(assetSpecifiers.collateralAsset).transferFrom(msg.sender, address(this), assetSpecifiers.collateralAmount);
        IERC20(assetSpecifiers.collateralAsset).approve(ICollarEngine(engine).dexRouter(), assetSpecifiers.collateralAmount);
        uint256 cashAmount = ISwapRouter(payable(ICollarEngine(engine).dexRouter())).exactInputSingle(swapParams);

        // mark LTV as withdrawable and the rest as locked
        uint256 unlockedVaultCashTotal = (cashAmount * collarOpts.ltv) / 10000;
        uint256 lockedVaultCashTotal = cashAmount - unlockedVaultCashTotal;

        // increment vault count
        vaultCount++;

        // generate UUID and set vault storage
        vaultUUID = keccak256(abi.encodePacked(user, vaultCount));

        vaultsByUUID[vaultUUID] = CollarVaultState.Vault(
            true,                               // vault is active
            block.timestamp,                    // vault creation timestamp
            collarOpts.expiry,                  // expiration date is +3 days
            collarOpts.ltv,                     // ltv is 90%

            liquidityOpts.liquidityPool,        // a collar liquidity pool address
            
            assetSpecifiers.cashAsset,          // an erc20 token
            assetSpecifiers.collateralAsset,    // an erc20 token
            cashAmount,                         // the amount of tokens received in the trade
            assetSpecifiers.collateralAmount,   // the amount of tokens initially provided

            liquidityOpts.ticks,                // the tick specifiers for the liquidity pool
            liquidityOpts.ratios,               // the ratio specifiers for the liquidity pool

            lockedVaultCashTotal,               // the amount of cash locked in the vault
            liquidityOpts.totalLiquidity,       // the amount of cash locked in the pool
            unlockedVaultCashTotal              // the amount of cash unlocked in the vault
        );

        vaultUUIDsByIndex[vaultCount] = vaultUUID;
        vaultIndexByUUID[vaultUUID] = vaultCount;

        tokenVaultCount[assetSpecifiers.cashAsset]++;
        tokenTotalBalance[assetSpecifiers.cashAsset] += assetSpecifiers.collateralAmount;

        // emit event
        emit CollarVaultManagerEvents.VaultOpened(vaultUUID);

        return vaultUUID;
    }

    function finalizeVault(bytes32 vaultUUID) external override vaultExists(vaultUUID) {
        /* steps

            1) validate input (vault exsits, is active, and is expired)
            2) calculate payouts and pull to/from vault/pool as needed
            3) mark vault as finalized

        */

        /* --- step 1: validate input (Vault exists, is active, and is expired) --- */

        // grab reference to the vault
        CollarVaultState.Vault storage vault = vaultsByUUID[vaultUUID];

        // verify vault is active & expired
        if (!vault.active) revert CollarVaultManagerErrors.InactiveVault(vaultUUID);
        if (vault.expiry < block.timestamp) revert CollarVaultManagerErrors.NotYetExpired(vaultUUID);

        /* --- step 2: calculate payouts and pull to/from vault/pool as needed ---

            scenario 1: close price < put

              85%        90%       95%      100%      105%      110%      115%      120%
               |         |         |         |         |         |         |         |        
            <--------------------------------------------------------------------------->
                  |      |                                       |   |
                  p     put                                      x   y      

            1) locked vault balance --> market maker / liquidity pool
            2) locked pool balance  --> market maker / liquidity pool
            3) unlock liquidity pool balance

            scenario 2: 100% > close price > put
            
              85%        90%       95%      100%      105%      110%      115%      120%
               |         |         |         |         |         |         |         |        
            <-------------------------------------------------------------------------->
                         |            |                          |   |
                        put           p                          x   y               

            1) locked vault balance partial --> user, locked vault balance partial --> market maker / liquidity pool
            2) locked pool balance --> market maker / liquidity pool
            3) unlock liquidity pool balance

            scenario 3: x & y > close price > 100%

              85%        90%       95%      100%      105%      110%      115%      120%
               |         |         |         |         |         |         |         |        
            <-------------------------------------------------------------------------->
                         |                             |         |   |
                        put                            p         x   y  

            1) locked vault balance --> user
            2) locked pool balance partial --> user, locked pool balance partial --> market maker / liquidity pool
            3) unlock liquidity pool balance

            scenario 4: y > close price > x

              85%        90%       95%      100%      105%      110%      115%      120%
               |         |         |         |         |         |         |         |        
            <-------------------------------------------------------------------------->
                         |                                       | | |
                        put                                      x p y  
                
            1) locked vault balance --> user
            2) locked pool balance x --> user
            3) locked pool balance y partial --> user, locked pool balance y partial --> market maker / liquidity pool
            4) unlock liquidity pool balance

            scenario 5: close price > x & y

              85%        90%       95%      100%      105%      110%      115%      120%
               |         |         |         |         |         |         |         |        
            <-------------------------------------------------------------------------->
                         |                                       |   |     |
                        put                                      x   y     p

            1) locked vault balance --> user
            2) locked pool balance --> user
        */

        // calculate payouts to user and/or market maker
        uint256 collateralPriceFinal = ICollarEngine(engine).getHistoricalAssetPrice(vault.collateralAsset, vault.expiry);

        // ltv = put-strike
        uint256 putStrikePrice = (vault.ltv * vault.cashAmount * 1e12) / 10_000;
        uint256 startingPrice = (vault.collateralAmount * 1e12) / vault.cashAmount;

        uint256 poolScaleFactor = CollarLiquidityPool(vault.liquidityPool).scaleFactor();

        uint24[] memory ticks = vault.callStrikeTicks;
        uint256[] memory tickRatios = vault.tickRatios;

        uint256[] memory payoutsToUserFromPool = new uint256[](ticks.length);
        uint256[] memory payoutsToUserFromVault = new uint256[](ticks.length);

        uint256[] memory payoutsToMarketMakersFromPool = new uint256[](ticks.length);
        uint256[] memory payoutsToMarketMakersFromVault = new uint256[](ticks.length);

        // each vault has a locked cash balance in the VAULT itself - this covers from the put strike to the starting price
        // each vault has a locked cash balance in the POOL itself - this covers from the starting price to the call strike

        // the locked amounts are distributed proportionally (according to the provided RATIOS array) at each tick

        // okay, let's build 4 arrays (we'll optimize later)

        // 1) how much we need to unlock from the vault at each tick to (re)-pay the user
        // 2) how much we need to pull from the pool at each tick to pay out the user
        // 3) how much we need to pull from the vault at each tick to pay out the market maker(s)
        // 4) how much we need to unlock from the pool at each tick to (re)-pay the market maker(s)

        bool BEARISH;
        bool DOWN_BAD;

        if (collateralPriceFinal <= putStrikePrice) {
            BEARISH = true;
            DOWN_BAD = true;

            // the final price of the collateral is LESS than the put strike price,
            // which means the market maker gets all POOL and VAULT locked liquidity

            for (uint256 tickIndex = 0; tickIndex < ticks.length; tickIndex++) {
                uint24 tick = ticks[tickIndex];
                uint256 ratio = tickRatios[tick];

                /*payoutsToUserFromVault[tick] = 0;*/
                /*payoutsToUserFromPool[tick] = 0;*/
                payoutsToMarketMakersFromVault[tick] = (ratio * vault.lockedVaultCashTotal) / 1e12;
                payoutsToMarketMakersFromPool[tick] = (ratio * vault.lockedPoolCashTotal) / 1e12;
            }

        } else if (collateralPriceFinal <= startingPrice) {
            BEARISH = true;
            DOWN_BAD = false;

            // the collateral price is GREATER than the put strike, but LESS than the starting price
            // this means the market makers get all their pool locked liquidity back
            // this means that user and market makers each get a slice of the vault locked liquidity

            uint256 totalPriceDistancePutSide = startingPrice - putStrikePrice;
            uint256 achievedPriceDistancePutSide = collateralPriceFinal - putStrikePrice;

            uint256 putStrikePriceRatioUserSide = (achievedPriceDistancePutSide * 1e12) / totalPriceDistancePutSide;
            uint256 putSrikePriceRatioMarketMakerSide = 1e12 - putStrikePriceRatioUserSide;

            for (uint256 tickIndex = 0; tickIndex < ticks.length; tickIndex++) {
                uint24 tick = ticks[tickIndex];
                uint256 ratio = tickRatios[tick];
                uint256 thisTickLockedVaultCashTotal = (ratio * vault.lockedVaultCashTotal) / 1e12;
                uint256 thisTickLockedPoolCashTotal = (ratio * vault.lockedPoolCashTotal) / 1e12;

                payoutsToUserFromVault[tick] = (putStrikePriceRatioUserSide * thisTickLockedVaultCashTotal) / 1e12;
                /*payoutsToUserFromPool[tick] = 0;*/
                payoutsToMarketMakersFromVault[tick] = (putSrikePriceRatioMarketMakerSide * thisTickLockedVaultCashTotal) / 1e12;
                payoutsToMarketMakersFromPool[tick] = thisTickLockedPoolCashTotal;
            }

        } else {
            BEARISH = false;
            DOWN_BAD = false;

            // the collateral price is GREATER than the starting price
            // this means the user gets all vault liquidity back
            // if the final price is GREATER than a given tick's price, all locked pool liquidty at that tick goes to the user
            // if the final price is LESS than a given tick's price, the pool liquidity is split between the user and the market maker

            for (uint256 tickIndex = 0; tickIndex < ticks.length; tickIndex++) {
                uint24 tick = ticks[tickIndex];
                uint256 ratio = tickRatios[tick];
                uint256 tickPrice = TickCalculations.tickToPrice(tick, poolScaleFactor, startingPrice);

                uint256 thisTickLockedVaultCashTotal = (ratio * vault.lockedVaultCashTotal) / 1e12;
                uint256 thisTickLockedPoolCashTotal = (ratio * vault.lockedPoolCashTotal) / 1e12;

                // go ahead and knock out the vault liquidty
                payoutsToUserFromVault[tick] = thisTickLockedVaultCashTotal;
                /*payoutsToMarketMakersFromVault[tick] = 0;*/

                if (collateralPriceFinal > tickPrice) {
                    // all locked pool liquidity at this tick goes to the user

                    payoutsToUserFromPool[tick] = thisTickLockedPoolCashTotal;
                    /*payoutsToMarketMakersFromPool[tick] = 0;*/

                } else {
                    // payouts of locked pool liquidity go proportionally to the user AND the market maker,
                    // depending on how close the final price is to the current tick's price

                    uint256 totalPriceDistanceCallSide = tickPrice - startingPrice;
                    uint256 achievedPriceDistance = collateralPriceFinal - startingPrice;

                    uint256 callStrikePriceRatioUserSide = (achievedPriceDistance * 1e12) / totalPriceDistanceCallSide;
                    uint256 callStrikePriceRatioMarketMakerSide = 1e12 - callStrikePriceRatioUserSide;

                    payoutsToUserFromPool[tick] = (callStrikePriceRatioUserSide * thisTickLockedPoolCashTotal) / 1e12;
                    payoutsToMarketMakersFromPool[tick] = (callStrikePriceRatioMarketMakerSide * thisTickLockedPoolCashTotal) / 1e12;
                }
            }
        }

        // we have now built 4 arrays:

        // 1) how much we need to unlock from the vault at each tick to (re)-pay the user
        // 2) how much we need to pull from the pool at each tick to pay out the user
        // 3) how much we need to pull from the vault at each tick to pay out the market maker(s)
        // 4) how much we need to unlock from the pool at each tick to (re)-pay the market maker(s)

        // now let's act on them, if applicable

        // 1) unlock from the vault at each tick to (re)-pay the user (!DOWN_BAD)
        // 2) unlock from the vault at each tick to (re)-pay the market maker(s) (BEARISH)
        // 3) pull from the pool at each tick to pay out the user (!BEARISH)
        // 4) pull from the pool at each tick to pay out the market maker(s) (TRUE)

        // 0) unlock all the liquidity used for this vault
        CollarLiquidityPool(vault.liquidityPool).unlockLiquidityAtTicks(vault.cashAmount, tickRatios, ticks);

        // 1) unlock from the vault at each tick to (re)-pay the user (!DOWN_BAD)
        if (!DOWN_BAD) {
            for (uint256 index = 0; index < payoutsToUserFromVault.length; index++) {
                uint256 amount = payoutsToUserFromVault[index];

                if (amount > 0) {
                    vault.lockedVaultCashTotal -= amount;
                    vault.unlockedVaultCashTotal += amount;
                }
            }
        }

        // 2) unlock from the vault at each tick to (re)-pay the market maker(s) (BEARISH)
        if (BEARISH) {
            CollarLiquidityPool(vault.liquidityPool).rewardLiquidityToTicks(payoutsToMarketMakersFromVault, ticks);
        }

        // 3) pull from the pool at each tick to pay out the user
        if (!BEARISH) {
            CollarLiquidityPool(vault.liquidityPool).withdrawFromTicks(address(this), payoutsToUserFromPool, ticks);
            
            // (and add to the unlocked balance for the vault)
            for (uint256 index = 0; index < payoutsToUserFromPool.length; index++) {
                uint256 amount = payoutsToUserFromPool[index];

                if (amount > 0) {
                    vault.unlockedVaultCashTotal += amount;
                }
            }
        }

        // 4) pull from the pool at each tick to pay out the market maker(s) (TRUE)
        // we don't actually need to do anything here since we already unlocked the liquidity!d


        /* --- step 3: mark vault as finalized --- */

        vault.active = false;
    }

    function depositCash(
        bytes32 vaultUUID, 
        uint256 amount, 
        address from
    ) external override vaultExists(vaultUUID) returns (uint256 newUnlockedCashBalance) {
        // grab reference to the vault
        CollarVaultState.Vault storage vault = vaultsByUUID[vaultUUID];
        
        // cache the token address
        address cashToken = vault.cashAsset;

        // increment the cash balance of this vault
        vault.unlockedVaultCashTotal += amount;

        // update the total balance tracker
        tokenTotalBalance[cashToken] += amount;

        // transfer in the cash
        IERC20(cashToken).transferFrom(from, address(this), amount);

        return vault.unlockedVaultCashTotal;
    }

    function withdrawCash(
        bytes32 vaultUUID, 
        uint256 amount, 
        address to
    ) external override vaultExists(vaultUUID) returns (uint256 newUnlockedCashBalance) {
        // grab refernce to the vault 
        CollarVaultState.Vault storage vault = vaultsByUUID[vaultUUID];

        // cache the token address
        address cashToken = vault.cashAsset;

        // decrement the token balance of the vault
        vault.unlockedVaultCashTotal -= amount;

        // update the total balance tracker
        tokenTotalBalance[cashToken] -= amount;

        // transfer out the cash
        IERC20(cashToken).transfer(to, amount);

        return vault.unlockedVaultCashTotal;
    }

    function validateAssets(CollarVaultState.AssetSpecifiers calldata assetSpecifiers) internal view {
        if (assetSpecifiers.cashAsset == address(0)) revert CollarVaultManagerErrors.InvalidAssetSpecifiers();
        if (assetSpecifiers.collateralAsset == address(0)) revert CollarVaultManagerErrors.InvalidAssetSpecifiers();
        if (assetSpecifiers.cashAmount == 0) revert CollarVaultManagerErrors.InvalidAssetSpecifiers();
        if (assetSpecifiers.collateralAmount == 0) revert CollarVaultManagerErrors.InvalidAssetSpecifiers();

        // verify validity of assets
        if (!(ICollarEngine(engine)).isSupportedCashAsset(assetSpecifiers.cashAsset)) revert CashAssetNotSupported(assetSpecifiers.cashAsset);    
        if (!(ICollarEngine(engine)).isSupportedCollateralAsset(assetSpecifiers.collateralAsset)) revert CollateralAssetNotSupported(assetSpecifiers.collateralAsset);  
    }

    function validateOpts(CollarVaultState.CollarOpts calldata collarOpts) internal view {
        // very expiry / length
        uint256 collarLength = collarOpts.expiry - block.timestamp; // calculate how long the collar will be
        if (!(ICollarEngine(engine)).isValidCollarLength(collarLength)) revert CollarLengthNotSupported(collarLength);
    }

    function validateLiquidity(CollarVaultState.LiquidityOpts calldata liquidityOpts) internal pure {
        // verify amounts & ticks are equal; specific ticks and amoutns verified in transfer step
        /*if (liquidityOpts.amounts.length != liquidityOpts.ticks.length) revert InvalidLiquidityOpts();*/
    }
}