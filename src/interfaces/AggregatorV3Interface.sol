// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title AggregatorV3Interface
/// @notice Minimal subset of Chainlink's AggregatorV3Interface used by EthUsdReader.
/// @dev Function signatures match the canonical Chainlink interface exactly, so the
///      compiled selectors are identical to the ones the live feed proxies expose.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
