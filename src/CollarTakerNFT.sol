// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import { ConfigHub, BaseNFT, CollarProviderNFT, Math, IERC20, SafeERC20 } from "./CollarProviderNFT.sol";
import { ITakerOracle } from "./interfaces/ITakerOracle.sol";
import { ICollarTakerNFT } from "./interfaces/ICollarTakerNFT.sol";
import { ICollarProviderNFT } from "./interfaces/ICollarProviderNFT.sol";

/**
 * @title CollarTakerNFT
 * @custom:security-contact security@collarprotocol.xyz
 *
 * Main Functionality:
 * 1. Manages the taker side of collar positions - handling position creation and settlement.
 * 2. Mints NFTs representing taker positions, allowing cancellations, rolls,
 *    and a secondary market for unexpired positions.
 * 3. Settles positions at expiry by calculating final payouts using oracle prices.
 * 4. Handles cancellation and withdrawal of settled positions.
 *
 * Role in the Protocol:
 * This contract acts as the core engine for the Collar Protocol, working in tandem with
 * CollarProviderNFT to create zero-sum paired positions. It holds and calculates the taker's side of
 * collars, which is typically wrapped by LoansNFT to create loan positions.
 *
 * Key Assumptions and Prerequisites:
 * 1. Takers must be able to receive ERC-721 tokens to withdraw earnings.
 * 2. The allowed provider contracts are trusted and properly implemented.
 * 3. The ConfigHub contract correctly manages protocol parameters and authorization.
 * 4. Asset (ERC-20) contracts are simple, non rebasing, do not allow reentrancy, balance changes
 *    correspond to transfer arguments.
 *
 * Post-Deployment Configuration:
 * - Oracle: Ensure adequate observation cardinality
 * - ConfigHub: Set setCanOpenPair() to authorize this contract for its asset pair
 * - ConfigHub: Set setCanOpenPair() to authorize the provider contract
 * - CollarProviderNFT: Ensure properly configured
 */
contract CollarTakerNFT is ICollarTakerNFT, BaseNFT {
    using SafeERC20 for IERC20;
    using SafeCast for uint;

    uint internal constant BIPS_BASE = 10_000;

    string public constant VERSION = "0.2.0";

    // ----- IMMUTABLES ----- //
    IERC20 public immutable cashAsset;
    IERC20 public immutable underlying; // not used as ERC20 here

    // ----- STATE VARIABLES ----- //
    ITakerOracle public oracle;

    mapping(uint positionId => TakerPositionStored) internal positions;

    constructor(
        address initialOwner,
        ConfigHub _configHub,
        IERC20 _cashAsset,
        IERC20 _underlying,
        ITakerOracle _oracle,
        string memory _name,
        string memory _symbol
    ) BaseNFT(initialOwner, _name, _symbol) {
        cashAsset = _cashAsset;
        underlying = _underlying;
        _setConfigHub(_configHub);
        _setOracle(_oracle);
        emit CollarTakerNFTCreated(address(_cashAsset), address(_underlying), address(_oracle));
    }

    // ----- VIEW FUNCTIONS ----- //

    /// @notice Returns the ID of the next taker position to be minted
    function nextPositionId() external view returns (uint) {
        return nextTokenId;
    }

    /// @notice Retrieves the details of a specific position (corresponds to the NFT token ID)
    function getPosition(uint takerId) public view returns (TakerPosition memory) {
        TakerPositionStored memory stored = positions[takerId];
        // do not try to call non-existent provider
        require(address(stored.providerNFT) != address(0), "taker: position does not exist");
        // @dev the provider position fields that are used are assumed to be immutable (set once)
        ICollarProviderNFT.ProviderPosition memory providerPos =
            stored.providerNFT.getPosition(stored.providerId);
        return TakerPosition({
            providerNFT: stored.providerNFT,
            providerId: stored.providerId,
            duration: providerPos.duration, // comes from the offer, implicitly checked with expiration
            expiration: providerPos.expiration, // checked to match on creation
            startPrice: stored.startPrice,
            putStrikePercent: providerPos.putStrikePercent,
            callStrikePercent: providerPos.callStrikePercent,
            takerLocked: stored.takerLocked,
            providerLocked: providerPos.providerLocked, // assumed immutable
            settled: stored.settled,
            withdrawable: stored.withdrawable
        });
    }

    /// @notice Expiration time and settled state of a specific position (corresponds to the NFT token ID)
    /// @dev This is more gas efficient than SLOADing everything in getPosition if just expiration / settled
    /// is needed
    function expirationAndSettled(uint takerId) external view returns (uint expiration, bool settled) {
        TakerPositionStored storage stored = positions[takerId];
        return (stored.providerNFT.expiration(stored.providerId), stored.settled);
    }

    /**
     * @notice Calculates the amount of cash asset that will be locked on provider side
     * for a given amount of taker locked asset and strike percentages.
     * @param takerLocked The amount of cash asset locked by the taker
     * @param putStrikePercent The put strike percentage in basis points
     * @param callStrikePercent The call strike percentage in basis points
     * @return The amount of cash asset the provider will lock
     */
    function calculateProviderLocked(uint takerLocked, uint putStrikePercent, uint callStrikePercent)
        public
        pure
        returns (uint)
    {
        // cannot be 0 due to range checks in providerNFT and configHub
        uint putRange = BIPS_BASE - putStrikePercent;
        uint callRange = callStrikePercent - BIPS_BASE;
        // proportionally scaled according to ranges. Will div-zero panic for 0 putRange.
        // rounds down against of taker to prevent taker abuse by opening small positions
        return takerLocked * callRange / putRange;
    }

    /// @notice Returns the price used for opening positions, which is current price from
    /// the oracle.
    /// @return Amount of cashAsset for a unit of underlying (i.e. 10**underlying.decimals())
    function currentOraclePrice() public view returns (uint) {
        return oracle.currentPrice();
    }

    /// @notice Returns the price that's used in this contract for settling positions. If the
    /// historical price is unavailable, it falls back to the current price. This allows
    /// settlement to occur any time after expiry, but at a potentially different price than if
    /// called soon after expiry.
    /// @return price Amount of cashAsset for a unit of underlying (i.e. 10**underlying.decimals())
    /// @return historical Whether the returned price is historical (true) or the current price (false)
    function historicalOraclePrice(uint timestamp) public view returns (uint price, bool historical) {
        return oracle.pastPriceWithFallback(timestamp.toUint32());
    }

    /**
     * @notice Calculates the settlement results at a given price
     * @dev no validation, so may revert with division by zero for bad values
     * @param position The TakerPosition to calculate settlement for
     * @param endPrice The settlement price, as returned from the this contract's price views
     * @return takerBalance The amount the taker will be able to withdraw after settlement
     * @return providerDelta The amount transferred to/from provider position (positive or negative)
     */
    function previewSettlement(TakerPosition memory position, uint endPrice)
        external
        pure
        returns (uint takerBalance, int providerDelta)
    {
        return _settlementCalculations(position, endPrice);
    }

    // ----- STATE CHANGING FUNCTIONS ----- //

    /**
     * @notice Opens a new paired taker and provider position: minting taker NFT position to the caller,
     * and calling provider NFT mint provider position to the provider.
     * @dev The caller must have approved this contract to transfer the takerLocked amount
     * @param takerLocked The amount to pull from sender, to be locked on the taker side
     * @param providerNFT The CollarProviderNFT contract of the provider
     * @param offerId The offer ID on the provider side. Implies specific provider,
     * put & call percents, duration.
     * @return takerId The ID of the newly minted taker NFT
     * @return providerId The ID of the newly minted provider NFT
     */
    function openPairedPosition(uint takerLocked, CollarProviderNFT providerNFT, uint offerId)
        external
        whenNotPaused
        returns (uint takerId, uint providerId)
    {
        // check asset & self allowed
        require(configHub.canOpenPair(underlying, cashAsset, address(this)), "taker: unsupported taker");
        // check assets & provider allowed
        require(
            configHub.canOpenPair(underlying, cashAsset, address(providerNFT)), "taker: unsupported provider"
        );
        // check assets match
        require(providerNFT.underlying() == underlying, "taker: underlying mismatch");
        require(providerNFT.cashAsset() == cashAsset, "taker: cashAsset mismatch");

        CollarProviderNFT.LiquidityOffer memory offer = providerNFT.getOffer(offerId);
        require(offer.duration != 0, "taker: invalid offer");
        uint providerLocked =
            calculateProviderLocked(takerLocked, offer.putStrikePercent, offer.callStrikePercent);

        // prices
        uint startPrice = currentOraclePrice();
        (uint putStrikePrice, uint callStrikePrice) =
            _strikePrices(offer.putStrikePercent, offer.callStrikePercent, startPrice);
        // avoid boolean edge cases and division by zero when settling
        require(
            putStrikePrice < startPrice && callStrikePrice > startPrice, "taker: strike prices not different"
        );

        // open the provider position for providerLocked amount (reverts if can't).
        // sends the provider NFT to the provider
        providerId = providerNFT.mintFromOffer(offerId, providerLocked, nextTokenId);

        // check expiration matches expected
        uint expiration = block.timestamp + offer.duration;
        require(expiration == providerNFT.expiration(providerId), "taker: expiration mismatch");

        // increment ID
        takerId = nextTokenId++;
        // store position data
        positions[takerId] = TakerPositionStored({
            providerNFT: providerNFT,
            providerId: SafeCast.toUint64(providerId),
            settled: false, // unset until settlement
            startPrice: startPrice,
            takerLocked: takerLocked,
            withdrawable: 0 // unset until settlement
         });
        // mint the NFT to the sender, @dev does not use _safeMint to avoid reentrancy
        _mint(msg.sender, takerId);

        emit PairedPositionOpened(takerId, address(providerNFT), providerId, offerId, takerLocked, startPrice);

        // pull the user side of the locked cash
        cashAsset.safeTransferFrom(msg.sender, address(this), takerLocked);
    }

    /**
     * @notice Settles a paired position after expiry. Tries to use historical price, if unavailable
     * falls back to current.
     * @param takerId The ID of the taker position to settle
     *
     * @dev this should be called as soon after expiry as possible, because if the expiry TWAP
     * price becomes unavailable in the UniV3 oracle, the current price will be used instead of it.
     * Both taker and provider are incentivised to call this method, however it's possible that
     * one side is not (e.g., due to being at max loss). For this reason a keeper should be run to
     * prevent users with gains from not settling their positions on time.
     * @dev To increase the timespan during which the historical price is available use
     * `oracle.increaseCardinality` (or the pool's `increaseObservationCardinalityNext`).
     */
    function settlePairedPosition(uint takerId) external whenNotPaused {
        // @dev this checks position exists
        TakerPosition memory position = getPosition(takerId);

        require(block.timestamp >= position.expiration, "taker: not expired");
        require(!position.settled, "taker: already settled");

        // settlement price
        (uint endPrice, bool historical) = historicalOraclePrice(position.expiration);
        // settlement amounts
        (uint takerBalance, int providerDelta) = _settlementCalculations(position, endPrice);

        // store changes
        positions[takerId].settled = true;
        positions[takerId].withdrawable = takerBalance;

        (CollarProviderNFT providerNFT, uint providerId) = (position.providerNFT, position.providerId);
        // settle paired and make the transfers
        if (providerDelta > 0) cashAsset.forceApprove(address(providerNFT), uint(providerDelta));
        providerNFT.settlePosition(providerId, providerDelta);

        emit PairedPositionSettled(
            takerId, address(providerNFT), providerId, endPrice, historical, takerBalance, providerDelta
        );
    }

    /// @notice Withdraws funds from a settled position. Burns the NFT.
    /// @param takerId The ID of the settled position to withdraw from (NFT token ID).
    /// @return withdrawal The amount of cash asset withdrawn
    function withdrawFromSettled(uint takerId) external whenNotPaused returns (uint withdrawal) {
        require(msg.sender == ownerOf(takerId), "taker: not position owner");

        TakerPosition memory position = getPosition(takerId);
        require(position.settled, "taker: not settled");

        withdrawal = position.withdrawable;
        // store zeroed out withdrawable
        positions[takerId].withdrawable = 0;
        // burn token
        _burn(takerId);
        // transfer tokens
        cashAsset.safeTransfer(msg.sender, withdrawal);

        emit WithdrawalFromSettled(takerId, withdrawal);
    }

    /**
     * @notice Cancels a paired position and withdraws funds
     * @dev Can only be called by the owner of BOTH taker and provider NFTs
     * @param takerId The ID of the taker position to cancel
     * @return withdrawal The amount of funds withdrawn from both positions together
     */
    function cancelPairedPosition(uint takerId) external whenNotPaused returns (uint withdrawal) {
        TakerPosition memory position = getPosition(takerId);
        (CollarProviderNFT providerNFT, uint providerId) = (position.providerNFT, position.providerId);

        // must be taker NFT owner
        require(msg.sender == ownerOf(takerId), "taker: not owner of ID");
        // must be provider NFT owner as well
        require(msg.sender == providerNFT.ownerOf(providerId), "taker: not owner of provider ID");

        // must not be settled yet
        require(!position.settled, "taker: already settled");

        // storage changes. withdrawable is 0 before settlement, so needs no update
        positions[takerId].settled = true;
        // burn token
        _burn(takerId);

        // cancel and withdraw
        uint providerWithdrawal = providerNFT.cancelAndWithdraw(providerId);

        // transfer the tokens locked in this contract and the withdrawal from provider
        withdrawal = position.takerLocked + providerWithdrawal;
        cashAsset.safeTransfer(msg.sender, withdrawal);

        emit PairedPositionCanceled(
            takerId, address(providerNFT), providerId, withdrawal, position.expiration
        );
    }

    // ----- Owner Mutative ----- //

    /// @notice Sets the price oracle used by the contract
    /// @param _oracle The new price oracle to use
    function setOracle(ITakerOracle _oracle) external onlyOwner {
        _setOracle(_oracle);
    }

    // ----- INTERNAL MUTATIVE ----- //

    // internal owner

    function _setOracle(ITakerOracle _oracle) internal {
        // assets match
        require(_oracle.baseToken() == address(underlying), "taker: oracle underlying mismatch");
        require(_oracle.quoteToken() == address(cashAsset), "taker: oracle cashAsset mismatch");

        // Ensure price calls don't revert and return a non-zero price at least right now.
        // Only a sanity check, since this doesn't ensure that it will work in the future,
        // since the observations buffer can be filled such that the required time window is not available.
        // @dev this means this contract can be temporarily DoSed unless the cardinality is set
        // to at least twap-window. For 5 minutes TWAP on Arbitrum this is 300 (obs. are set by timestamps)
        require(_oracle.currentPrice() != 0, "taker: invalid current price");
        (uint price,) = _oracle.pastPriceWithFallback(uint32(block.timestamp));
        require(price != 0, "taker: invalid past price");

        // check these views don't revert (part of the interface used in Loans)
        // note: .convertToBaseAmount(price, price) should equal .baseUnitAmount(), but checking this
        // may be too strict for more complex oracles, and .baseUnitAmount() is not used internally now
        require(_oracle.convertToBaseAmount(price, price) != 0, "taker: invalid convertToBaseAmount");

        emit OracleSet(oracle, _oracle); // emit before for the prev value
        oracle = _oracle;
    }

    // ----- INTERNAL VIEWS ----- //

    // calculations

    function _strikePrices(uint putStrikePercent, uint callStrikePercent, uint startPrice)
        internal
        pure
        returns (uint putStrikePrice, uint callStrikePrice)
    {
        putStrikePrice = startPrice * putStrikePercent / BIPS_BASE;
        callStrikePrice = startPrice * callStrikePercent / BIPS_BASE;
    }

    function _settlementCalculations(TakerPosition memory position, uint endPrice)
        internal
        pure
        returns (uint takerBalance, int providerDelta)
    {
        uint startPrice = position.startPrice;
        (uint putStrikePrice, uint callStrikePrice) =
            _strikePrices(position.putStrikePercent, position.callStrikePercent, startPrice);

        // restrict endPrice to put-call range
        endPrice = Math.max(Math.min(endPrice, callStrikePrice), putStrikePrice);

        // start with locked (corresponds to endPrice == startPrice)
        takerBalance = position.takerLocked;
        // endPrice == startPrice is no-op in both branches
        if (endPrice < startPrice) {
            // takerLocked: divided between taker and provider
            // providerLocked: all goes to provider
            uint providerGainRange = startPrice - endPrice;
            uint putRange = startPrice - putStrikePrice;
            uint providerGain = position.takerLocked * providerGainRange / putRange; // no div-zero ensured on open
            takerBalance -= providerGain;
            providerDelta = providerGain.toInt256();
        } else {
            // takerLocked: all goes to taker
            // providerLocked: divided between taker and provider
            uint takerGainRange = endPrice - startPrice;
            uint callRange = callStrikePrice - startPrice;
            uint takerGain = position.providerLocked * takerGainRange / callRange; // no div-zero ensured on open

            takerBalance += takerGain;
            providerDelta = -takerGain.toInt256();
        }
    }
}
