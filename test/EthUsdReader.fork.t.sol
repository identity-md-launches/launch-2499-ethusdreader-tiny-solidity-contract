// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {EthUsdReader} from "../src/EthUsdReader.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Mainnet fork tests against the live Chainlink ETH/USD feed.
/// @dev MAINNET_RPC_URL may be a URL or a socket path. Only an empty value skips
///      these tests; a configured endpoint that fails must fail the suite.
contract EthUsdReaderForkTest is Test {
    /// @dev Chainlink ETH/USD aggregator proxy on Ethereum mainnet.
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev Mainnet block at which the fork is pinned (2026-10-23).
    uint256 internal constant FORK_BLOCK = 26_252_703;

    /// @dev Chainlink's ETH/USD heartbeat is 3600 s; allow that plus some slack.
    uint256 internal constant MAX_AGE = 3 hours;

    EthUsdReader internal reader;

    modifier onMainnetFork() {
        string memory url = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(url, FORK_BLOCK);
        assertEq(block.chainid, 1, "expected Ethereum mainnet");
        assertEq(block.number, FORK_BLOCK, "unexpected fork block");
        reader = new EthUsdReader(ETH_USD_FEED, MAX_AGE);
        _;
    }

    function testFork_feedIsTheMainnetEthUsdAggregator() public onMainnetFork {
        assertGt(ETH_USD_FEED.code.length, 0, "feed has no code");
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED);
        assertEq(feed.decimals(), 8, "ETH/USD feed must report 8 decimals");
        assertEq(feed.decimals(), reader.DECIMALS(), "feed decimals differ from DECIMALS");
        assertEq(feed.description(), "ETH / USD");
    }

    function testFork_latestPriceReturnsLivePrice() public onMainnetFork {
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        (uint256 price, uint256 updatedAt) = reader.latestPrice();

        assertGt(answer, 0, "live feed answer must be positive");
        assertEq(price, uint256(answer), "price must match the feed answer verbatim");
        assertEq(updatedAt, feedUpdatedAt, "updatedAt must match the feed");
        assertGt(updatedAt, 0, "live feed round must be complete");
        assertLe(updatedAt, block.timestamp, "feed update must not be in the future");
        assertLe(block.timestamp - updatedAt, MAX_AGE, "fork block answer must be within maxAge");

        // Sanity bounds on a real ETH/USD quote with 8 decimals: $100 to $100,000.
        assertGt(price, 100e8, "price implausibly low");
        assertLt(price, 100_000e8, "price implausibly high");
    }

    function testFork_anyCallerCanReadLivePrice() public onMainnetFork {
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        vm.prank(makeAddr("price consumer"));
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(answer));
        assertEq(updatedAt, feedUpdatedAt);
    }

    function testFork_revertsWhenLiveAnswerIsStale() public onMainnetFork {
        (uint256 originalPrice, uint256 updatedAt) = reader.latestPrice();

        // Exactly at the limit is still accepted.
        vm.warp(updatedAt + MAX_AGE);
        (uint256 priceAtLimit, uint256 timestampAtLimit) = reader.latestPrice();
        assertEq(priceAtLimit, originalPrice);
        assertEq(timestampAtLimit, updatedAt);

        // One second past the limit is refused.
        vm.warp(updatedAt + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        reader.latestPrice();
    }

    function testFork_tightMaxAgeRefusesOlderAnswer() public onMainnetFork {
        (uint256 originalPrice, uint256 updatedAt) = reader.latestPrice();
        // Ensure a positive age even if the feed was updated in the pinned block.
        // This changes only the EVM clock, never the pinned chain state.
        uint256 laterTimestamp = vm.getBlockTimestamp() + 2;
        vm.warp(laterTimestamp);
        uint256 age = laterTimestamp - updatedAt;

        EthUsdReader tight = new EthUsdReader(ETH_USD_FEED, age - 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        tight.latestPrice();

        EthUsdReader exact = new EthUsdReader(ETH_USD_FEED, age);
        (uint256 price, uint256 exactUpdatedAt) = exact.latestPrice();
        assertEq(price, originalPrice);
        assertEq(exactUpdatedAt, updatedAt);
    }

    function testFork_rejectsNonPositiveMockedFeedAnswers() public onMainnetFork {
        // Keep the real feed as the target but mock its answer to a non-positive value.
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, int256(0), startedAt, updatedAt, answeredInRound)
        );
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(0)));
        reader.latestPrice();

        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(roundId, int256(-5), startedAt, updatedAt, answeredInRound)
        );
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(-5)));
        reader.latestPrice();

        vm.clearMockedCalls();
        (uint256 price,) = reader.latestPrice();
        assertGt(price, 0);
    }
}
