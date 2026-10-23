// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {EthUsdReader} from "../src/EthUsdReader.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Mainnet fork tests against the live Chainlink ETH/USD feed.
/// @dev The fork is pinned to a fixed block so the assertions are reproducible. The
///      endpoint comes from `[rpc_endpoints]` in foundry.toml, never from the
///      environment. When the endpoint is unreachable (the verifier runs offline)
///      every test in this contract is skipped rather than failed.
contract EthUsdReaderForkTest is Test {
    /// @dev Chainlink ETH/USD aggregator proxy on Ethereum mainnet.
    address internal constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev Mainnet block at which the fork is pinned (2026-10-23).
    uint256 internal constant FORK_BLOCK = 26_252_743;

    /// @dev Chainlink's ETH/USD heartbeat is 3600 s; allow that plus some slack.
    uint256 internal constant MAX_AGE = 3 hours;

    EthUsdReader internal reader;
    bool internal forked;

    function setUp() public {
        try vm.createSelectFork("mainnet", FORK_BLOCK) {
            forked = true;
        } catch {
            forked = false;
            return;
        }
        reader = new EthUsdReader(ETH_USD_FEED, MAX_AGE);
    }

    modifier onlyForked() {
        vm.skip(!forked);
        _;
    }

    function testFork_feedIsTheMainnetEthUsdAggregator() public onlyForked {
        assertGt(ETH_USD_FEED.code.length, 0, "feed has no code");
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED);
        assertEq(feed.decimals(), reader.DECIMALS(), "feed decimals differ from DECIMALS");
        assertEq(feed.description(), "ETH / USD");
    }

    function testFork_latestPriceReturnsLivePrice() public onlyForked {
        (, int256 answer,, uint256 feedUpdatedAt,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();

        (uint256 price, uint256 updatedAt) = reader.latestPrice();

        assertEq(price, uint256(answer), "price must match the feed answer verbatim");
        assertEq(updatedAt, feedUpdatedAt, "updatedAt must match the feed");
        assertLe(block.timestamp - updatedAt, MAX_AGE, "fork block answer must be within maxAge");

        // Sanity bounds on a real ETH/USD quote with 8 decimals: between 1 USD and 1,000,000 USD.
        assertGt(price, 1e8, "price implausibly low");
        assertLt(price, 1_000_000e8, "price implausibly high");
    }

    function testFork_latestPriceMatchesPinnedBlockValue() public onlyForked {
        // Value observed on the live feed at FORK_BLOCK; a different value means the
        // fork is not the block we expect.
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, 240_636_106_115);
        assertEq(updatedAt, 1_792_726_379);
    }

    function testFork_revertsWhenLiveAnswerIsStale() public onlyForked {
        (, uint256 updatedAt) = reader.latestPrice();

        // Exactly at the limit is still accepted.
        vm.warp(updatedAt + MAX_AGE);
        reader.latestPrice();

        // One second past the limit is refused.
        vm.warp(updatedAt + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        reader.latestPrice();
    }

    function testFork_tightMaxAgeRefusesOlderAnswer() public onlyForked {
        (, uint256 updatedAt) = reader.latestPrice();
        uint256 age = block.timestamp - updatedAt;
        vm.assume(age > 1);

        EthUsdReader tight = new EthUsdReader(ETH_USD_FEED, age - 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        tight.latestPrice();

        EthUsdReader exact = new EthUsdReader(ETH_USD_FEED, age);
        (uint256 price,) = exact.latestPrice();
        assertGt(price, 0);
    }

    function testFork_revertsWhenLiveFeedReportsBadPrice() public onlyForked {
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
