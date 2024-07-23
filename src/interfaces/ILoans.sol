// SPDX-License-Identifier: MIT

/*
 * Copyright (c) 2023 Collar Networks, Inc. <hello@collarprotocolentAsset.xyz>
 * All rights reserved. No warranty, explicit or implicit, provided.
 */

pragma solidity 0.8.22;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { CollarEngine } from "../implementations/CollarEngine.sol";
import { CollarTakerNFT } from "../CollarTakerNFT.sol";
import { ProviderPositionNFT } from "../ProviderPositionNFT.sol";
import { Rolls } from "../Rolls.sol";

interface ILoans {
    struct Loan {
        uint collateralAmount;
        uint loanAmount;
        address keeperAllowedBy;
        bool active;
    }

    // events
    event LoanCreated(
        address indexed sender,
        address indexed providerNFT,
        uint indexed offerId,
        uint collateralAmount,
        uint loanAmount,
        uint takerId,
        uint providerId
    );
    event LoanClosed(
        uint indexed takerId,
        address indexed sender,
        address indexed user,
        uint repayment,
        uint cashAmount,
        uint collateralOut
    );
    event LoanRolled(
        address indexed sender,
        uint indexed takerId,
        uint indexed rollId,
        uint newTakerId,
        uint loanAmount,
        uint newLoanAmount,
        int transferAmount
    );
    event ClosingKeeperAllowed(address indexed sender, uint indexed takerId, bool indexed enabled);
    event ClosingKeeperUpdated(address indexed previousKeeper, address indexed newKeeper);
    event RollsContractUpdated(Rolls indexed previousRolls, Rolls indexed newRolls);

    // constants
    function MAX_SWAP_TWAP_DEVIATION_BIPS() external view returns (uint);
    function VERSION() external view returns (string memory);

    // immutables
    function cashAsset() external view returns (IERC20);
    function collateralAsset() external view returns (IERC20);
    function engine() external view returns (CollarEngine);
    function takerNFT() external view returns (CollarTakerNFT);
    // state
    function getLoan(uint takerId) external view returns (Loan memory);
    function closingKeeper() external view returns (address);
    // mutative contract owner
    function setKeeper(address keeper) external;
    function setRollsContract(Rolls rolls) external;
    // mutative user / keeper
    function createLoan(
        uint collateralAmount,
        uint minLoanAmount,
        uint minSwapCash,
        ProviderPositionNFT providerNFT,
        uint offerId
    ) external returns (uint takerId, uint providerId, uint loanAmount);
    function setKeeperAllowedBy(uint takerId, bool enabled) external;
    function closeLoan(uint takerId, uint minCollateralAmount) external returns (uint collateralReturned);
    function rollLoan(uint takerId, Rolls rolls, uint rollId, int minToUser)
        external
        returns (uint newTakerId, uint newLoanAmount, int transferAmount);
}
