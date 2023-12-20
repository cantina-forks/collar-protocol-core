// SPDX-License-Identifier: MIT

/*
 * Copyright (c) 2023 Collar Networks, Inc. <hello@collarprotocolentAsset.xyz>
 * All rights reserved. No warranty, explicit or implicit, provided.
 */

pragma solidity ^0.8.18;

import { ICollarPool } from "../interfaces/ICollarPool.sol";
import { Constants, CollarVaultState } from "../libs/CollarLibs.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CollarPool is ICollarPool, Constants {
    constructor(address _engine, uint256 _tickScaleFactor, address _cashAsset) ICollarPool(_engine, _tickScaleFactor, _cashAsset) {}

    function getSlot(
        uint256 slotIndex
    ) external override view returns (SlotState memory) {
        return slots[slotIndex];
    }

    function addLiquidity(
        uint256 slotIndex,
        uint256 amount
    ) external virtual override {
        bool freeSlotFound = false;
        bool smallSlotFound = false;
        uint256 freeSlotIndex = type(uint256).max;
        uint256 smallestSlotIndex = type(uint256).max;
        uint256 smallestAmountSoFar = type(uint256).max;

        // check if provider already has a slot here first
        
        if (providerLiquidityBySlot[msg.sender][slotIndex] > 0) {
            freeSlotFound = true;
            
            // iterate to find which index it is
            for (uint256 i = 0; i < slots[slotIndex].providers.length; i++) {
                if (slots[slotIndex].providers[i] == msg.sender) {
                    freeSlotIndex = i;
                }
            }
        }

        // check if destination slot has space - if not, check to see if this provider has rights to kick out smallest provider
        SlotState storage slot = slots[slotIndex];

        // if this is the first time we're touching this slot, we need to initialize the arrays
        if (slot.providers.length == 0) {
            slot.providers = new address[](5);
            slot.amounts = new uint256[](5);
            freeSlotFound = true;
            freeSlotIndex = 0;
        }

        if (!freeSlotFound) {
            revert("NO SIR");
            for (uint256 i = 0; i < slot.providers.length; i++) {
                if (slot.providers[i] == address(0)) {
                    // found an empty slot - allocate here
                    slot.providers[i] = msg.sender;
                    slot.amounts[i] = amount;
                    freeSlotFound = true;
                    break;
                } else if (slot.amounts[i] < amount && slot.amounts[i] < smallestAmountSoFar) {
                    // found a slot with less liquidity than the amount we want to allocate
                    // keep track of the smallest slot we've seen so far
                    smallestSlotIndex = i;
                    smallestAmountSoFar = slot.amounts[i];
                    smallSlotFound = true;
                }
            } 
        }

        if (!freeSlotFound && !smallSlotFound) {
            revert("No available slots at destination, sorry!");
        }

        if (!freeSlotFound && smallSlotFound) {
            // kick out smallest provider
            address smallestProvider = slot.providers[smallestSlotIndex];

            // moved smallest guy's balance to the unallocated slot
            providerLiquidityBySlot[smallestProvider][slotIndex] = 0;
            providerLiquidityBySlot[smallestProvider][UNALLOCATED_SLOT] += smallestAmountSoFar;

            // allocate new guy to the slot where the smallest guy was
            slot.providers[smallestSlotIndex] = msg.sender;
            slot.amounts[smallestSlotIndex] = amount;
            providerLiquidityBySlot[msg.sender][slotIndex] = amount;

            // update total slot liquidity
            slotLiquidity[slotIndex] -= smallestAmountSoFar;
            slotLiquidity[slotIndex] += amount;

            slot.liquidity -= smallestAmountSoFar;
            slot.liquidity += amount;
        }

        if (freeSlotFound) {
            if (slot.providers[freeSlotIndex] != address(0) && slot.providers[freeSlotIndex] != msg.sender) {
                revert("Slot already allocated to another provider");
            }

            if (slot.providers[freeSlotIndex] == address(0)) {
                // this is a new provider, so we need to add them to the list
                slot.providers[freeSlotIndex] = msg.sender;
            }

            slot.amounts[freeSlotIndex] += amount;
            providerLiquidityBySlot[msg.sender][slotIndex] += amount;
        }

        // transfer collateral from provider to pool
        IERC20(cashAsset).transferFrom(msg.sender, address(this), amount);

        // update total slot liquidity amount
        slotLiquidity[slotIndex] += amount;
        slot.liquidity += amount;
    }

    function removeLiquidity(
        uint256 slot,
        uint256 amount
    ) external virtual override {

        // verify free liquidity in slot
        if (providerLiquidityBySlot[msg.sender][slot] < amount) {
            revert("Not enough liquidity");
        }

        // find index of provider in slot
        uint256 providerSlot = type(uint256).max;
        for (uint256 i = 0; i < slots[slot].providers.length; i++) {
            if (slots[slot].providers[i] == msg.sender) {
                providerSlot = i;
                break;
            }
        }

        // send to provider & decrement balance
        slots[slot].amounts[providerSlot] -= amount;
        providerLiquidityBySlot[msg.sender][slot] -= amount;
        IERC20(cashAsset).transfer(msg.sender, amount);

        // update global bals too
        slotLiquidity[slot] -= amount;
        slots[slot].liquidity -= amount;
    }

    function reallocateLiquidity(
        uint256 sourceSlotIndex,
        uint256 destinationSlotIndex,
        uint256 amount
    ) external virtual override {

        // verify free liquidity in slot
        if (providerLiquidityBySlot[msg.sender][sourceSlotIndex] < amount) {
            revert("Not enough liquidity");
        }

        // check if destination slot has space - if not, check to see if this provider has rights to kick out smallest provider
        SlotState storage destinationSlot = slots[destinationSlotIndex];
        SlotState storage sourceSlot = slots[sourceSlotIndex];

        // iterate to find availability
        bool freeSlotFound = false;
        bool smallSlotFound = false;
        uint256 smallestSlotIndex = type(uint256).max;
        uint256 smallestAmountSoFar = type(uint256).max;
        for (uint256 i = 0; i < destinationSlot.providers.length; i++) {
            if (destinationSlot.providers[i] == address(0)) {
                // found an empty slot - allocate here
                destinationSlot.providers[i] = msg.sender;
                destinationSlot.amounts[i] = amount;
                freeSlotFound = true;
                break;
            } else if (destinationSlot.amounts[i] < amount && destinationSlot.amounts[i] < smallestAmountSoFar) {
                // found a slot with less liquidity than the amount we want to allocate
                // keep track of the smallest slot we've seen so far
                smallestSlotIndex = i;
                smallestAmountSoFar = destinationSlot.amounts[i];
                smallSlotFound = true;
            }
        }

        if (!freeSlotFound && !smallSlotFound) {
            revert("No available slots at destination, sorry!");
        }

        if (!freeSlotFound && smallSlotFound) {
            // kick out smallest provider
            address smallestProvider = destinationSlot.providers[smallestSlotIndex];

            // moved smallest guy's balance to the unallocated slot
            providerLiquidityBySlot[smallestProvider][destinationSlotIndex] = 0;
            providerLiquidityBySlot[smallestProvider][UNALLOCATED_SLOT] += smallestAmountSoFar;

            // allocate new guy to the slot where the smallest guy was
            destinationSlot.providers[smallestSlotIndex] = msg.sender;
            destinationSlot.amounts[smallestSlotIndex] = amount;
            providerLiquidityBySlot[msg.sender][destinationSlotIndex] = amount;

            // finally, unallocated the source slot
            providerLiquidityBySlot[msg.sender][sourceSlotIndex] -= amount;
            
            for(uint256 i = 0; i < sourceSlot.providers.length; i++) {
                if (sourceSlot.providers[i] == msg.sender) {
                    sourceSlot.providers[i] = address(0);
                    sourceSlot.amounts[i] = 0;
                    break;
                }
            }
        }
    }

    function mint(bytes32 uuid, uint256 slot, uint256 amount) external override {
        // ensure this is the first/only mint
        if (hasMinted[uuid]) {
            revert("Already minted");
        }

        // ensure this is a valid vault calling us - it must call through the engine
        if (msg.sender != engine) {
            revert("Only engine can mint");
        }

        // ensure there is enough liquidity available
        if (slotLiquidity[slot] < amount) {
            revert("Not enough liquidity");
        }

        // allocate evenly from all providers
        address[] memory providers = slots[slot].providers;

        uint256[] memory amounts = new uint256[](providers.length);

        uint256 totalSlotLiquidity = slotLiquidity[slot];

        for (uint256 i = 0; i < providers.length; i++) {
            // calculate how much to pull from provider based off of their proportional ownership of liquidity in this slot
            address thisProvider = providers[i];
            uint256 providerLiquidity = providerLiquidityBySlot[thisProvider][slot];

            // this provider's liquidity to pull = 
            // (provider's proportional ownership of slot liquidity) * (total amount needed)
            // (providerLiquidity / totalSlotLiquidity) * amount
            // (providerLiquidity * amount) / totalSlotLiquidity
            uint256 amountFromThisProvider = (providerLiquidity * amount) / totalSlotLiquidity;
            amounts[i] = amountFromThisProvider;
        }

        // mint tokens for this new vault to all providers in slot & decrement their liquidity amounts
        for (uint256 i = 0; i < providers.length; i++) {
            providerLiquidityBySlot[providers[i]][slot] -= amounts[i];
            _mint(providers[i], uint256(uuid), amounts[i]);
        }

        // decrement available liquidity in slot
        slotLiquidity[slot] -= amount;

        // mark this vault as having minted so that it can't be double-called
        hasMinted[uuid] = true;
    }

    function redeem(bytes32 uuid, uint256 amount) external override {
        // ensure vault is finalized
        if (!vaultStatus[uuid]) {
            revert("Vault not finalized");
        }

        // calculate cash redeem value
        uint256 redeemValue = previewRedeem(uuid, amount);

        // redeem to user & burn tokens
        _burn(msg.sender, uint256(uuid), amount);
        IERC20(cashAsset).transfer(msg.sender, redeemValue);
    }

    function previewRedeem(bytes32 uuid, uint256 amount) public override view returns (uint256 cashReceived) {
        bool finalized = !vaultStatus[uuid];

        if (finalized) {
            // if finalized, calculate final redeem value
            // grab collateral asset value @ exact vault expiration time

            uint256 _totalTokenCashSupply = totalCashSupplyForToken[uuid];
            uint256 _totalTokenSupply = totalTokenSupply[uint256(uuid)];

            cashReceived = (_totalTokenCashSupply * amount) / _totalTokenSupply;

        } else {
            revert("Not implemented");
        }
    }

    function vaultPullLiquidity(
        bytes32 uuid,
        address receiver,
        uint256 amount
    ) external override {
        // verify caller via engine
        if (msg.sender != engine) {
            revert("Only engine can pull liquidity");
        } 

        // update the amount of total cash tokens for that vault
        totalCashSupplyForToken[uuid] -= amount;

        // transfer liquidity
        IERC20(cashAsset).transferFrom(address(this), receiver, amount);
    }

    function vaultPushLiquidity(
        bytes32 uuid,
        address sender,
        uint256 amount
    ) external override {
        // verify caller via engine
        if (msg.sender != engine) {
            revert("Only engine can push liquidity");
        }

        // update the amount of total cash tokens for that vault
        totalCashSupplyForToken[uuid] += amount;

        // transfer liquidity
        IERC20(cashAsset).transferFrom(sender, address(this), amount);
    }

    function finalizeVault(
        bytes32 uuid
    ) external override {
        // ensure that this is a valid vault calling us - it must call through the engine
        if (msg.sender != engine) {
            revert("Only engine can finalize");
        }

        // ensure that this vault has not already been finalized
        if (vaultStatus[uuid]) {
            revert("Already finalized");
        }

        // finalize the vault
        vaultStatus[uuid] = true;
    }

    function _mint(address account, uint256 id, uint256 amount) internal override {
        // update total supply of token
        totalTokenSupply[id] += amount;

        super._mint(account, id, amount);
    }
    
    function _burn(address account, uint256 id, uint256 amount) internal override {
        // update total supply of token
        totalTokenSupply[id] -= amount;

        super._burn(account, id, amount);
    }
}