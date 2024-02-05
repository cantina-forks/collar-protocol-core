// SPDX-License-Identifier: MIT

/*
 * Copyright (c) 2023 Collar Networks, Inc. <hello@collarprotocolentAsset.xyz>
 * All rights reserved. No warranty, explicit or implicit, provided.
 */

pragma solidity ^0.8.18;

import { ICollarEngine } from "../interfaces/ICollarEngine.sol";
import { CollarVaultManager } from "./CollarVaultManager.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract CollarEngine is ICollarEngine, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    modifier ensureValidLiquidityPool(address pool) {
        if (!collarLiquidityPools.contains(pool)) revert InvalidLiquidityPool(pool);
        _;
    }

    modifier ensureNotValidLiquidityPool(address pool) {
        if (collarLiquidityPools.contains(pool)) revert LiquidityPoolAlreadyAdded(pool);
        _;
    }

    modifier ensureValidCollateralAsset(address asset) {
        if (!supportedCollateralAssets.contains(asset)) revert CollateralAssetNotSupported(asset);
        _;
    }

    modifier ensureValidCashAsset(address asset) {
        if (!supportedCollateralAssets.contains(asset)) revert CashAssetNotSupported(asset);
        _;
    }

    modifier ensureValidAsset(address asset) {
        if (!supportedCashAssets.contains(asset) && !supportedCollateralAssets.contains(asset)) revert AssetNotSupported(asset);
        _;
    }

    modifier ensureNotValidCollateralAsset(address asset) {
        if (supportedCollateralAssets.contains(asset)) revert CollateralAssetAlreadySupported(asset);
        _;
    }

    modifier ensureNotValidCashAsset(address asset) {
        if (supportedCashAssets.contains(asset)) revert CashAssetAlreadySupported(asset);
        _;
    }

    modifier ensureNotValidAsset(address asset) {
        if (supportedCollateralAssets.contains(asset) || supportedCashAssets.contains(asset)) revert AssetAlreadySupported(asset);
        _;
    }

    modifier ensureSupportedCollarLength(uint256 length) {
        if (!validCollarLengths.contains(length)) revert CollarLengthNotSupported(length);
        _;
    }

    modifier ensureNotSupportedCollarLength(uint256 length) {
        if (validCollarLengths.contains(length)) revert CollarLengthNotSupported(length);
        _;
    }

    EnumerableSet.AddressSet private collarLiquidityPools;
    EnumerableSet.AddressSet private supportedCollateralAssets;
    EnumerableSet.AddressSet private supportedCashAssets;
    EnumerableSet.UintSet private validCollarLengths;

    constructor(address _dexRouter) ICollarEngine(_dexRouter) Ownable(msg.sender) { }

    function isSupportedCashAsset(address asset) external view returns (bool) {
        return supportedCashAssets.contains(asset);
    }

    function isSupportedCollateralAsset(address asset) external view returns (bool) {
        return supportedCollateralAssets.contains(asset);
    }

    function isSupportedLiquidityPool(address pool) external view returns (bool) {
        return collarLiquidityPools.contains(pool);
    }

    function isValidCollarLength(uint256 length) external view returns (bool) {
        return validCollarLengths.contains(length);
    }

    function createVaultManager() external override returns (address _vaultManager) {
        if (addressToVaultManager[msg.sender] != address(0)) {
            revert VaultManagerAlreadyExists(msg.sender, addressToVaultManager[msg.sender]);
        }

        address vaultManager = address(new CollarVaultManager(address(this), msg.sender));
        addressToVaultManager[msg.sender] = vaultManager;
        vaultManagers[vaultManager] = true;

        return vaultManager;
    }

    function addLiquidityPool(address pool) external override onlyOwner ensureNotValidLiquidityPool(pool) {
        collarLiquidityPools.add(pool);
    }

    function removeLiquidityPool(address pool) external override onlyOwner ensureValidLiquidityPool(pool) {
        collarLiquidityPools.remove(pool);
    }

    function addSupportedCollateralAsset(address asset) external override onlyOwner ensureNotValidCollateralAsset(asset) {
        supportedCollateralAssets.add(asset);
    }

    function removeSupportedCollateralAsset(address asset) external override onlyOwner ensureValidCollateralAsset(asset) {
        supportedCollateralAssets.remove(asset);
    }

    function addSupportedCashAsset(address asset) external override onlyOwner ensureNotValidCashAsset(asset) {
        supportedCashAssets.add(asset);
    }

    function removeSupportedCashAsset(address asset) external override onlyOwner ensureValidCashAsset(asset) {
        supportedCashAssets.remove(asset);
    }

    function addCollarLength(uint256 length) external override onlyOwner ensureNotSupportedCollarLength(length) {
        validCollarLengths.add(length);
    }

    function removeCollarLength(uint256 length) external override onlyOwner ensureSupportedCollarLength(length) {
        validCollarLengths.remove(length);
    }

    function getHistoricalAssetPrice(address, /*asset*/ uint256 /*timestamp*/ ) external view virtual override returns (uint256) {
        revert("Method not yet implemented");
    }

    function getCurrentAssetPrice(address asset) external view virtual override ensureValidAsset(asset) returns (uint256) {
        revert("Method not yet implemented");
    }

    function notifyFinalized(address pool, bytes32 uuid) external override ensureValidVaultManager(msg.sender) ensureValidLiquidityPool(pool) {
        revert("Method not yet implemented");
    }
}
