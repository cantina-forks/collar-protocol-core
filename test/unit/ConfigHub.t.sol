// SPDX-License-Identifier: MIT

/*
 * Copyright (c) 2023 Collar Networks, Inc. <hello@collarprotocolentAsset.xyz>
 * All rights reserved. No warranty, explicit or implicit, provided.
 */

pragma solidity 0.8.22;

import "forge-std/Test.sol";
import { TestERC20 } from "../utils/TestERC20.sol";
import { ConfigHub, IConfigHub, IShortProviderNFT, ICollarTakerNFT } from "../../src/ConfigHub.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract ConfigHubTest is Test {
    TestERC20 token1;
    TestERC20 token2;
    ConfigHub configHub;
    uint constant durationToUse = 1 days;
    uint constant minDurationToUse = 300;
    uint constant maxDurationToUse = 365 days;
    uint constant ltvToUse = 9000;
    uint constant minLTVToUse = 1000;
    uint constant maxLTVToUse = 9999;
    address router = makeAddr("router");
    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address guardian = makeAddr("guardian");

    bytes user1NotAuthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1);

    function setUp() public {
        token1 = new TestERC20("Test1", "TST1");
        token2 = new TestERC20("Test2", "TST2");
        configHub = new ConfigHub(owner);
    }

    function test_deploymentAndDeployParams() public {
        configHub = new ConfigHub(owner);
        assertEq(configHub.owner(), owner);
        assertEq(configHub.pendingOwner(), address(0));
        assertEq(configHub.VERSION(), "0.2.0");
        assertEq(configHub.MIN_CONFIGURABLE_LTV(), 1000);
        assertEq(configHub.MAX_CONFIGURABLE_LTV(), 9999);
        assertEq(configHub.MIN_CONFIGURABLE_DURATION(), 300);
        assertEq(configHub.MAX_CONFIGURABLE_DURATION(), 5 * 365 days);
        assertEq(configHub.pauseGuardian(), address(0));
        assertEq(configHub.feeRecipient(), address(0));
        assertEq(configHub.minDuration(), 0);
        assertEq(configHub.maxDuration(), 0);
        assertEq(configHub.protocolFeeAPR(), 0);
        assertEq(configHub.minLTV(), 0);
        assertEq(configHub.maxLTV(), 0);
    }

    function test_onlyOwnerAuth() public {
        startHoax(user1);

        vm.expectRevert(user1NotAuthorized);
        configHub.setTakerCanOpen(address(0), true);

        vm.expectRevert(user1NotAuthorized);
        configHub.setShortProviderCanOpen(address(0), true);

        vm.expectRevert(user1NotAuthorized);
        configHub.setLTVRange(0, 0);

        vm.expectRevert(user1NotAuthorized);
        configHub.setCollarDurationRange(0, 0);

        vm.expectRevert(user1NotAuthorized);
        configHub.setCollateralAssetSupport(address(0), true);

        vm.expectRevert(user1NotAuthorized);
        configHub.setCashAssetSupport(address(0), true);

        vm.expectRevert(user1NotAuthorized);
        configHub.setPauseGuardian(guardian);

        vm.expectRevert(user1NotAuthorized);
        configHub.setProtocolFeeParams(0, address(0));
    }

    function test_setCollarTakerContractAuth() public {
        startHoax(owner);
        address collarTakerContract = address(0x123);

        // Mock the cashAsset and collateralAsset calls
        vm.mockCall(
            collarTakerContract,
            abi.encodeWithSelector(ICollarTakerNFT.cashAsset.selector),
            abi.encode(address(token1))
        );
        vm.mockCall(
            collarTakerContract,
            abi.encodeWithSelector(ICollarTakerNFT.collateralAsset.selector),
            abi.encode(address(token2))
        );

        assertFalse(configHub.canOpen(collarTakerContract));

        vm.expectEmit(address(configHub));
        emit IConfigHub.CollarTakerNFTAuthSet(collarTakerContract, true, address(token1), address(token2));
        configHub.setTakerCanOpen(collarTakerContract, true);

        assertTrue(configHub.canOpen(collarTakerContract));

        // disabling
        vm.expectEmit(address(configHub));
        emit IConfigHub.CollarTakerNFTAuthSet(collarTakerContract, false, address(token1), address(token2));
        configHub.setTakerCanOpen(collarTakerContract, false);

        assertFalse(configHub.canOpen(collarTakerContract));
    }

    function test_setProviderContractAuth() public {
        startHoax(owner);
        address providerContract = address(0x456);

        // Mock the cashAsset, collateralAsset, and collarTakerContract calls
        vm.mockCall(
            providerContract,
            abi.encodeWithSelector(IShortProviderNFT.cashAsset.selector),
            abi.encode(address(token1))
        );
        vm.mockCall(
            providerContract,
            abi.encodeWithSelector(IShortProviderNFT.collateralAsset.selector),
            abi.encode(address(token2))
        );
        vm.mockCall(
            providerContract,
            abi.encodeWithSelector(IShortProviderNFT.taker.selector),
            abi.encode(address(0x789))
        );

        assertFalse(configHub.canOpen(providerContract));

        vm.expectEmit(address(configHub));
        emit IConfigHub.ProviderNFTAuthSet(
            providerContract, true, address(token1), address(token2), address(0x789)
        );
        configHub.setShortProviderCanOpen(providerContract, true);

        assertTrue(configHub.canOpen(providerContract));

        // disabling
        vm.expectEmit(address(configHub));
        emit IConfigHub.ProviderNFTAuthSet(
            providerContract, false, address(token1), address(token2), address(0x789)
        );
        configHub.setShortProviderCanOpen(providerContract, false);

        assertFalse(configHub.canOpen(providerContract));
    }

    function test_revert_setCollarTakerContractAuth_invalidContract() public {
        startHoax(owner);
        address invalidContract = address(0xABC);

        // fails to call non existing methods
        vm.expectRevert(new bytes(0));
        configHub.setTakerCanOpen(invalidContract, true);
    }

    function test_revert_setProviderContractAuth_invalidContract() public {
        startHoax(owner);
        address invalidContract = address(0xDEF);

        // fails to call non existing methods
        vm.expectRevert(new bytes(0));
        configHub.setShortProviderCanOpen(invalidContract, true);
    }

    function test_addSupportedCashAsset() public {
        startHoax(owner);
        assertFalse(configHub.isSupportedCashAsset(address(token1)));
        configHub.setCashAssetSupport(address(token1), true);
        assertTrue(configHub.isSupportedCashAsset(address(token1)));
    }

    function test_removeSupportedCashAsset() public {
        startHoax(owner);
        configHub.setCashAssetSupport(address(token1), true);
        configHub.setCashAssetSupport(address(token1), false);
        assertFalse(configHub.isSupportedCashAsset(address(token1)));
    }

    function test_addSupportedCollateralAsset() public {
        startHoax(owner);
        assertFalse(configHub.isSupportedCollateralAsset(address(token1)));
        configHub.setCollateralAssetSupport(address(token1), true);
        assertTrue(configHub.isSupportedCollateralAsset(address(token1)));
    }

    function test_removeSupportedCollateralAsset() public {
        startHoax(owner);
        configHub.setCollateralAssetSupport(address(token1), true);
        configHub.setCollateralAssetSupport(address(token1), false);
        assertFalse(configHub.isSupportedCollateralAsset(address(token1)));
    }

    function test_isValidDuration() public {
        startHoax(owner);
        configHub.setCollarDurationRange(minDurationToUse, maxDurationToUse);
        assertFalse(configHub.isValidCollarDuration(minDurationToUse - 1));
        assertTrue(configHub.isValidCollarDuration(minDurationToUse));
        assertTrue(configHub.isValidCollarDuration(maxDurationToUse));
        assertFalse(configHub.isValidCollarDuration(maxDurationToUse + 1));
    }

    function test_isValidLTV() public {
        startHoax(owner);
        configHub.setLTVRange(minLTVToUse, maxLTVToUse);
        assertFalse(configHub.isValidLTV(minLTVToUse - 1));
        assertTrue(configHub.isValidLTV(minLTVToUse));
        assertTrue(configHub.isValidLTV(maxLTVToUse));
        assertFalse(configHub.isValidLTV(maxLTVToUse + 1));
    }

    function test_setCollarTakerContractAuth_non_taker_contract() public {
        startHoax(owner);
        address testContract = address(0x123);
        // testContract doesnt support calling .cashAsset();
        vm.expectRevert();
        configHub.setTakerCanOpen(testContract, true);
        assertFalse(configHub.canOpen(testContract));
    }

    function test_setProviderContractAuth_non_taker_contract() public {
        startHoax(owner);
        address testContract = address(0x456);
        // testContract doesnt support calling .cashAsset();
        vm.expectRevert();
        configHub.setShortProviderCanOpen(testContract, true);
        assertFalse(configHub.canOpen(testContract));
    }

    function test_setLTVRange() public {
        startHoax(owner);
        vm.expectEmit(address(configHub));
        emit IConfigHub.LTVRangeSet(minLTVToUse, maxLTVToUse);
        configHub.setLTVRange(minLTVToUse, maxLTVToUse);
        assertEq(configHub.minLTV(), minLTVToUse);
        assertEq(configHub.maxLTV(), maxLTVToUse);
    }

    function test_revert_setLTVRange() public {
        startHoax(owner);
        vm.expectRevert("min > max");
        configHub.setLTVRange(maxLTVToUse, minLTVToUse);

        vm.expectRevert("min too low");
        configHub.setLTVRange(0, maxLTVToUse);

        vm.expectRevert("max too high");
        configHub.setLTVRange(minLTVToUse, 10_000);
    }

    function test_setDurationRange() public {
        startHoax(owner);
        vm.expectEmit(address(configHub));
        emit IConfigHub.CollarDurationRangeSet(minLTVToUse, maxDurationToUse);
        configHub.setCollarDurationRange(minLTVToUse, maxDurationToUse);
        assertEq(configHub.minDuration(), minLTVToUse);
        assertEq(configHub.maxDuration(), maxDurationToUse);
    }

    function test_revert_setCollarDurationRange() public {
        startHoax(owner);
        vm.expectRevert("min > max");
        configHub.setCollarDurationRange(maxDurationToUse, minDurationToUse);

        vm.expectRevert("min too low");
        configHub.setCollarDurationRange(0, maxDurationToUse);

        vm.expectRevert("max too high");
        configHub.setCollarDurationRange(minDurationToUse, 10 * 365 days);
    }

    function test_setPauseGuardian() public {
        startHoax(owner);
        vm.expectEmit(address(configHub));
        emit IConfigHub.PauseGuardianSet(address(0), guardian);
        configHub.setPauseGuardian(guardian);
        assertEq(configHub.pauseGuardian(), guardian);

        vm.expectEmit(address(configHub));
        emit IConfigHub.PauseGuardianSet(guardian, address(0));
        configHub.setPauseGuardian(address(0));
        assertEq(configHub.pauseGuardian(), address(0));
    }

    function test_setProtocolFeeParams() public {
        startHoax(owner);

        // reverts
        vm.expectRevert("invalid fee");
        configHub.setProtocolFeeParams(10_000 + 1, address(0)); // more than 100%

        vm.expectRevert("must set recipient for non-zero APR");
        configHub.setProtocolFeeParams(1, address(0));

        // effects
        vm.expectEmit(address(configHub));
        uint apr = 1;
        emit IConfigHub.ProtocolFeeParamsUpdated(0, apr, address(0), user1);
        configHub.setProtocolFeeParams(1, user1);
        assertEq(configHub.protocolFeeAPR(), apr);
        assertEq(configHub.feeRecipient(), user1);

        // unset
        vm.expectEmit(address(configHub));
        emit IConfigHub.ProtocolFeeParamsUpdated(apr, 0, user1, address(0));
        configHub.setProtocolFeeParams(0, address(0));
        assertEq(configHub.protocolFeeAPR(), 0);
        assertEq(configHub.feeRecipient(), address(0));
    }
}
