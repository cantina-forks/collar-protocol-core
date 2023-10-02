// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console2} from "forge-std/Test.sol";
import {CollarEngine} from "../../src/CollarEngine.sol";
import {ICollarEngine} from "../../src/interfaces/native/ICollarEngine.sol";
import {EngineUtils} from "../utils/EngineUtils.sol";
import {TestERC20} from "../utils/mocks/TestERC20.sol";
import {IERC20} from "@oz-v4.9.3/token/ERC20/IERC20.sol";
import {MockOracle} from "../utils/mocks/MockOracle.sol";

contract CollarEngineTest is Test, EngineUtils {
    CollarEngine engine;

    uint256 constant maturityTimestamp = 1_670_337_200;

    function setUp() public override {
        super.setUp();

        engine = deployEngine();

        MockOracle(DEFAULT_ENGINE_PARAMS.ethUSDOracle).setLatestRoundData(117_227_595_982);

        TestERC20(DEFAULT_ENGINE_PARAMS.usdc).mint(1e24);
        TestERC20(DEFAULT_ENGINE_PARAMS.usdc).mintTo(DEFAULT_ENGINE_PARAMS.marketMaker, 1e24);
    }

    function test_initialDeployAndValues() public {
        assertEq(engine.getAdmin(), DEFAULT_ENGINE_PARAMS.owner);
        assertEq(engine.getDexRouter(), DEFAULT_ENGINE_PARAMS.testDex);
        assertEq(engine.getMarketmaker(), DEFAULT_ENGINE_PARAMS.marketMaker);
        assertEq(engine.getFeewallet(), DEFAULT_ENGINE_PARAMS.feeWallet);
        assertEq(engine.getLendAsset(), DEFAULT_ENGINE_PARAMS.usdc);
        assertEq(engine.getFeerate(), DEFAULT_ENGINE_PARAMS.rake);
    }

    function test_getOraclePrice() public {
        uint256 oraclePrice = engine.getOraclePrice();
        assertEq(oraclePrice, 1_172_275_959_820_000_000_000);
    }

    function test_updateDexRouter() public {
        hoax(DEFAULT_ENGINE_PARAMS.owner);
        engine.updateDexRouter(0x0000000000000000000000000000000000000001);
        address newDexRouter = engine.getDexRouter();
        assertEq(newDexRouter, 0x0000000000000000000000000000000000000001);
    }

    function test_requestPrice() public {
        uint256 currentRFQId = engine.getCurrRfqid();
        assertEq(currentRFQId, DEFAULT_RFQID);

        startHoax(DEFAULT_ENGINE_PARAMS.trader);

        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        currentRFQId = engine.getCurrRfqid();
        assertEq(currentRFQId, DEFAULT_RFQID + 1);

        CollarEngine.Pricing memory traderPrice = engine.getPricingByClient(DEFAULT_ENGINE_PARAMS.trader);

        assertEq(traderPrice.rfqid, DEFAULT_RFQID);
        assertEq(traderPrice.lendAsset, DEFAULT_ENGINE_PARAMS.usdc);
        assertEq(traderPrice.marketmaker, DEFAULT_ENGINE_PARAMS.marketMaker);
        assertEq(traderPrice.client, DEFAULT_ENGINE_PARAMS.trader);
        assertEq(traderPrice.structure, "Prepaid");
        assertEq(traderPrice.underlier, "ETH");
        assertEq(traderPrice.maturityTimestamp, maturityTimestamp);
        assertEq(traderPrice.qty, DEFAULT_QTY);
        assertEq(traderPrice.ltv, DEFAULT_LTV);
        assertEq(traderPrice.putstrikePct, DEFAULT_PUT_STRIKE_PCT);
        assertEq(traderPrice.callstrikePct, 0);
        assertEq(traderPrice.notes, "");
    }

    // enum PxState{NEW, REQD, ACKD, PXD, OFF, REJ, DONE}
    //              0    1     2     3    4    5    6

    function test_ackPrice() public {
        ICollarEngine.PxState traderState;

        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");
        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.REQD);

        hoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.ACKD);
    }

    function test_showPrice() public {
        CollarEngine.PxState traderState;

        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.ACKD);

        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.PXD);
    }

    function test_pullPrice() public {
        CollarEngine.PxState traderState;

        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.PXD);

        engine.pullPrice(DEFAULT_ENGINE_PARAMS.trader);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.OFF);
    }

    function test_clientGiveOrder() public {
        ICollarEngine.PxState traderState;

        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.PXD);

        startHoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.clientGiveOrder{value: DEFAULT_QTY}();
        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.DONE);
    }

    function test_executeTrade() public {
        ICollarEngine.PxState traderState;

        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);

        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        startHoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.clientGiveOrder{value: DEFAULT_QTY}();

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        IERC20(DEFAULT_ENGINE_PARAMS.usdc).approve(address(engine), 1e18);
        engine.executeTrade(DEFAULT_ENGINE_PARAMS.trader);

        traderState = engine.getStateByClient(DEFAULT_ENGINE_PARAMS.trader);
        assertTrue(traderState == ICollarEngine.PxState.NEW);

        uint256 engineUSDCBalance = IERC20(DEFAULT_ENGINE_PARAMS.usdc).balanceOf(address(engine));
        assertLt(engineUSDCBalance, 10);

        uint256 engineETHBalance = address(engine).balance;
        assertEq(engineETHBalance, 0);
    }

    function test_updateFeeRatePct() public {
        uint256 feeRate;

        feeRate = engine.getFeerate();
        assertEq(feeRate, DEFAULT_RAKE);

        hoax(DEFAULT_ENGINE_PARAMS.owner);
        engine.updateFeeRatePct(5);

        feeRate = engine.getFeerate();
        assertEq(feeRate, 5);
    }

    function test_clientPullOrder() public {
        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        startHoax(DEFAULT_ENGINE_PARAMS.trader);
        uint256 traderBalancePre = address(DEFAULT_ENGINE_PARAMS.trader).balance;
        engine.clientGiveOrder{value: DEFAULT_QTY}();
        uint256 traderBalanceMid = address(DEFAULT_ENGINE_PARAMS.trader).balance;

        uint256 traderEscrow = engine.getClientEscrow(DEFAULT_ENGINE_PARAMS.trader);
        assertEq(traderEscrow, DEFAULT_QTY);

        engine.clientPullOrder();
        uint256 traderBalancePost = address(DEFAULT_ENGINE_PARAMS.trader).balance;

        assertApproxEqRel(traderBalancePre, traderBalancePost, 1);
        assertApproxEqRel(traderBalancePre - traderBalanceMid, DEFAULT_QTY, 1);
    }

    function test_rejectOrder() public {
        hoax(DEFAULT_ENGINE_PARAMS.trader);
        engine.requestPrice(DEFAULT_QTY, DEFAULT_LTV, maturityTimestamp, "");

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.ackPrice(DEFAULT_ENGINE_PARAMS.trader);
        engine.showPrice(DEFAULT_ENGINE_PARAMS.trader, DEFAULT_CALL_STRIKE_PCT);

        startHoax(DEFAULT_ENGINE_PARAMS.trader);
        uint256 traderBalancePre = address(DEFAULT_ENGINE_PARAMS.trader).balance;
        engine.clientGiveOrder{value: DEFAULT_QTY}();
        uint256 traderBalanceMid = address(DEFAULT_ENGINE_PARAMS.trader).balance;

        uint256 traderEscrow = engine.getClientEscrow(DEFAULT_ENGINE_PARAMS.trader);
        assertEq(traderEscrow, DEFAULT_QTY);

        startHoax(DEFAULT_ENGINE_PARAMS.marketMaker);
        engine.rejectOrder(DEFAULT_ENGINE_PARAMS.trader, "mkt moved");

        uint256 traderBalancePost = address(DEFAULT_ENGINE_PARAMS.trader).balance;

        traderEscrow = engine.getClientEscrow(DEFAULT_ENGINE_PARAMS.trader);
        assertEq(traderEscrow, 0);

        assertApproxEqRel(traderBalancePre, traderBalancePost, 1);
        assertApproxEqRel(traderBalancePre - traderBalanceMid, DEFAULT_QTY, 1);
    }
}
