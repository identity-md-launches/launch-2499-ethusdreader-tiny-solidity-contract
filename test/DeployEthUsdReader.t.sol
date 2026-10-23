// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployEthUsdReader} from "../script/DeployEthUsdReader.s.sol";
import {EthUsdReader} from "../src/EthUsdReader.sol";

/// @notice Exercises the deploy script's `deploy` function directly, without broadcasting.
contract DeployEthUsdReaderTest is Test {
    DeployEthUsdReader internal deployer;

    function setUp() public {
        deployer = new DeployEthUsdReader();
    }

    function test_deployUsesMainnetConstants() public {
        EthUsdReader reader = deployer.deploy(deployer.MAINNET_ETH_USD_FEED(), deployer.MAINNET_MAX_AGE());
        assertEq(address(reader.aggregator()), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        assertEq(reader.maxAge(), 3 hours);
    }

    function test_deployRejectsZeroAggregator() public {
        vm.expectRevert(EthUsdReader.ZeroAggregator.selector);
        deployer.deploy(address(0), 3 hours);
    }

    function test_deployRejectsZeroMaxAge() public {
        address feed = deployer.MAINNET_ETH_USD_FEED();
        vm.expectRevert(EthUsdReader.ZeroMaxAge.selector);
        deployer.deploy(feed, 0);
    }
}
