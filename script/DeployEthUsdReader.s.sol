// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";

import {EthUsdReader} from "../src/EthUsdReader.sol";

/// @notice Deploys EthUsdReader against the mainnet Chainlink ETH/USD feed.
/// @dev Configuration is held in constants and passed to `deploy`, which tests call
///      directly. `run()` only broadcasts; it reads nothing from the environment.
contract DeployEthUsdReader is Script {
    /// @dev Chainlink ETH/USD aggregator proxy on Ethereum mainnet.
    address public constant MAINNET_ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    /// @dev The mainnet ETH/USD feed heartbeat is 1 hour; three hours tolerates a
    ///      missed heartbeat without accepting a day-old quote.
    uint256 public constant MAINNET_MAX_AGE = 3 hours;

    function deploy(address aggregator, uint256 maxAge) public returns (EthUsdReader reader) {
        reader = new EthUsdReader(aggregator, maxAge);
    }

    function run() external returns (EthUsdReader reader) {
        vm.startBroadcast();
        reader = deploy(MAINNET_ETH_USD_FEED, MAINNET_MAX_AGE);
        vm.stopBroadcast();
    }
}
