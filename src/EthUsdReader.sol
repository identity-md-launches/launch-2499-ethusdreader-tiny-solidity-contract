// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title EthUsdReader
/// @notice Reads the ETH/USD price from a Chainlink price feed and refuses a stale or
///         non-positive answer. Holds no tokens, has no owner and no mutable state.
/// @dev Both configuration values are immutable and set once at construction. The
///      constructor performs no external calls, so the contract can be deployed on a
///      chain where the feed does not exist yet; the feed is checked on first use.
contract EthUsdReader {
    /// @notice Thrown when the feed's last update is older than `maxAge` seconds.
    /// @param updatedAt The feed's reported update timestamp.
    error StalePrice(uint256 updatedAt);

    /// @notice Thrown when the feed reports a zero or negative answer.
    /// @param answer The feed's reported answer.
    error BadPrice(int256 answer);

    /// @notice Thrown when the constructor receives the zero address as the aggregator.
    error ZeroAggregator();

    /// @notice Thrown when the constructor receives a zero `maxAge`.
    error ZeroMaxAge();

    /// @notice Number of decimals in the price returned by `latestPrice()`.
    /// @dev This mirrors the Chainlink ETH/USD feed, which reports 8 decimals. The value
    ///      is not read from the feed at construction (see contract notes); the fork test
    ///      confirms it against the live mainnet feed.
    uint8 public constant DECIMALS = 8;

    /// @notice The Chainlink aggregator (proxy) this reader queries.
    AggregatorV3Interface public immutable aggregator;

    /// @notice Maximum accepted age of the feed's latest answer, in seconds.
    uint256 public immutable maxAge;

    /// @param aggregator_ Address of the Chainlink ETH/USD aggregator proxy.
    /// @param maxAge_ Maximum accepted answer age in seconds. Must be greater than zero.
    constructor(address aggregator_, uint256 maxAge_) {
        if (aggregator_ == address(0)) revert ZeroAggregator();
        if (maxAge_ == 0) revert ZeroMaxAge();
        aggregator = AggregatorV3Interface(aggregator_);
        maxAge = maxAge_;
    }

    /// @notice Returns the feed's latest ETH/USD price and the time it was updated.
    /// @dev Reverts with `StalePrice(updatedAt)` when `block.timestamp - updatedAt > maxAge`
    ///      and with `BadPrice(answer)` when `answer <= 0`. An `updatedAt` in the future is
    ///      treated as age zero rather than underflowing. A revert from the feed itself
    ///      bubbles up unchanged.
    /// @return price The latest answer, with the feed's decimals (8 for ETH/USD).
    /// @return updatedAt The timestamp at which the feed last updated its answer.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt) {
        int256 answer;
        // roundId, startedAt and answeredInRound are intentionally ignored (see README).
        // forge-lint: disable-next-line(unused-return)
        (, answer,, updatedAt,) = aggregator.latestRoundData();

        if (updatedAt < block.timestamp && block.timestamp - updatedAt > maxAge) {
            revert StalePrice(updatedAt);
        }
        if (answer <= 0) revert BadPrice(answer);

        // casting to 'uint256' is safe because answer > 0 was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer);
    }
}
