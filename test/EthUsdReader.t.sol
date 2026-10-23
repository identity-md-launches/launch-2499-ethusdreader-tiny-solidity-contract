// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {EthUsdReader} from "../src/EthUsdReader.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice Unit and fuzz tests for EthUsdReader against a controllable mock feed.
contract EthUsdReaderTest is Test {
    uint256 internal constant MAX_AGE = 3600;
    int256 internal constant PRICE = 240_636_106_115; // 2406.36106115 USD with 8 decimals
    uint256 internal constant START = 1_792_727_375;

    MockAggregatorV3 internal feed;
    EthUsdReader internal reader;

    function setUp() public {
        vm.warp(START);
        feed = new MockAggregatorV3(8);
        feed.setRound(1, PRICE, START, START, 1);
        reader = new EthUsdReader(address(feed), MAX_AGE);
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    function test_constructor_setsImmutables() public view {
        assertEq(address(reader.aggregator()), address(feed));
        assertEq(reader.maxAge(), MAX_AGE);
        assertEq(reader.DECIMALS(), 8);
    }

    function test_constructor_revertsOnZeroAggregator() public {
        vm.expectRevert(EthUsdReader.ZeroAggregator.selector);
        new EthUsdReader(address(0), MAX_AGE);
    }

    function test_constructor_revertsOnZeroMaxAge() public {
        vm.expectRevert(EthUsdReader.ZeroMaxAge.selector);
        new EthUsdReader(address(feed), 0);
    }

    function test_constructor_doesNotCallAggregator() public {
        // Deploying against an address with no code must succeed: the launch
        // checks run the constructor on an empty chain.
        address noCode = address(0xBEEF);
        assertEq(noCode.code.length, 0);
        EthUsdReader r = new EthUsdReader(noCode, MAX_AGE);
        assertEq(address(r.aggregator()), noCode);
    }

    function test_noStorage() public view {
        // "No other state": the reader keeps nothing in storage. Immutables and
        // constants live in code, so every storage slot stays zero.
        for (uint256 slot = 0; slot < 8; slot++) {
            assertEq(vm.load(address(reader), bytes32(slot)), bytes32(0));
        }
    }

    // ---------------------------------------------------------------------
    // Success paths
    // ---------------------------------------------------------------------

    function test_latestPrice_freshAnswer() public view {
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(PRICE));
        assertEq(updatedAt, START);
    }

    function test_latestPrice_exactlyMaxAgeIsFresh() public {
        vm.warp(START + MAX_AGE);
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(PRICE));
        assertEq(updatedAt, START);
    }

    function test_latestPrice_futureUpdatedAtIsFresh() public {
        feed.setAnswer(PRICE, START + 10);
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(PRICE));
        assertEq(updatedAt, START + 10);
    }

    function test_latestPrice_smallestPositiveAnswer() public {
        feed.setAnswer(1, START);
        (uint256 price,) = reader.latestPrice();
        assertEq(price, 1);
    }

    function test_latestPrice_maxAnswer() public {
        feed.setAnswer(type(int256).max, START);
        (uint256 price,) = reader.latestPrice();
        assertEq(price, uint256(type(int256).max));
    }

    function test_latestPrice_recoversAfterFeedUpdates() public {
        vm.warp(START + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, START));
        reader.latestPrice();

        feed.setAnswer(PRICE + 1e8, block.timestamp);
        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(PRICE + 1e8));
        assertEq(updatedAt, block.timestamp);
    }

    function test_latestPrice_usesUpdatedAtRatherThanRoundStart() public {
        // A round can start long before its answer is published. Freshness is
        // measured from publication, and the returned timestamp must match it.
        feed.setRound(2, PRICE + 1e8, START - MAX_AGE - 1, START - 1, 2);

        (uint256 price, uint256 updatedAt) = reader.latestPrice();
        assertEq(price, uint256(PRICE + 1e8));
        assertEq(updatedAt, START - 1);
    }

    function test_latestPrice_doesNotFallBackToPreviousGoodAnswer() public {
        (uint256 firstPrice,) = reader.latestPrice();
        assertEq(firstPrice, uint256(PRICE));

        feed.setAnswer(0, START);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(0)));
        reader.latestPrice();

        feed.setAnswer(-1, START);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(-1)));
        reader.latestPrice();

        feed.setShouldRevert(true);
        vm.expectRevert(bytes("MockAggregatorV3: forced revert"));
        reader.latestPrice();

        feed.setShouldRevert(false);
        vm.warp(START + 1);
        feed.setAnswer(PRICE + 1e8, START + 1);
        (uint256 nextPrice, uint256 updatedAt) = reader.latestPrice();
        assertEq(nextPrice, uint256(PRICE + 1e8));
        assertEq(updatedAt, START + 1);
    }

    function test_latestPrice_maximumMaxAgeDoesNotOverflow() public {
        EthUsdReader r = new EthUsdReader(address(feed), type(uint256).max);
        feed.setAnswer(PRICE, 1);
        vm.warp(type(uint256).max);

        // Adding maxAge to updatedAt would overflow, but this answer's age is
        // representable and strictly less than the configured maximum.
        (uint256 price, uint256 updatedAt) = r.latestPrice();
        assertEq(price, uint256(PRICE));
        assertEq(updatedAt, 1);
    }

    function test_latestPrice_isViewAndCallableByAnyone() public {
        vm.prank(address(0x1234));
        (uint256 price,) = reader.latestPrice();
        assertEq(price, uint256(PRICE));
    }

    // ---------------------------------------------------------------------
    // Failure paths
    // ---------------------------------------------------------------------

    function test_latestPrice_revertsWhenOneSecondPastMaxAge() public {
        vm.warp(START + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, START));
        reader.latestPrice();
    }

    function test_latestPrice_revertsWhenUpdatedAtIsZero() public {
        feed.setAnswer(PRICE, 0);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, 0));
        reader.latestPrice();
    }

    function test_latestPrice_revertsAtMaximumTimestamp() public {
        feed.setAnswer(PRICE, 1);
        vm.warp(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, uint256(1)));
        reader.latestPrice();
    }

    function test_latestPrice_revertsOnZeroAnswer() public {
        feed.setAnswer(0, START);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(0)));
        reader.latestPrice();
    }

    function test_latestPrice_revertsOnNegativeAnswer() public {
        feed.setAnswer(-1, START);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, int256(-1)));
        reader.latestPrice();
    }

    function test_latestPrice_revertsOnMinAnswer() public {
        feed.setAnswer(type(int256).min, START);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, type(int256).min));
        reader.latestPrice();
    }

    function test_latestPrice_staleTakesPrecedenceOverBadPrice() public {
        feed.setAnswer(0, START);
        vm.warp(START + MAX_AGE + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, START));
        reader.latestPrice();
    }

    function test_latestPrice_bubblesFeedRevert() public {
        feed.setShouldRevert(true);
        vm.expectRevert(bytes("MockAggregatorV3: forced revert"));
        reader.latestPrice();
    }

    function test_latestPrice_revertsWhenAggregatorHasNoCode() public {
        EthUsdReader r = new EthUsdReader(address(0xBEEF), MAX_AGE);
        // High-level call to an address without code reverts before any decoding.
        vm.expectRevert();
        r.latestPrice();
    }

    // ---------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_freshPositiveAnswerIsReturned(int256 answer, uint256 age, uint256 maxAge) public {
        answer = bound(answer, 1, type(int256).max);
        maxAge = bound(maxAge, 1, type(uint64).max);
        age = bound(age, 0, maxAge);

        EthUsdReader r = new EthUsdReader(address(feed), maxAge);
        uint256 now_ = START + maxAge;
        vm.warp(now_);
        feed.setAnswer(answer, now_ - age);

        (uint256 price, uint256 updatedAt) = r.latestPrice();
        assertEq(price, uint256(answer));
        assertEq(updatedAt, now_ - age);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_staleAnswerReverts(int256 answer, uint256 excess, uint256 maxAge) public {
        maxAge = bound(maxAge, 1, type(uint64).max);
        excess = bound(excess, 1, type(uint64).max);

        EthUsdReader r = new EthUsdReader(address(feed), maxAge);
        uint256 now_ = START + maxAge + excess;
        vm.warp(now_);
        uint256 updatedAt = now_ - maxAge - excess;
        feed.setAnswer(answer, updatedAt);

        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        r.latestPrice();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_nonPositiveAnswerReverts(int256 answer, uint256 age) public {
        answer = bound(answer, type(int256).min, 0);
        age = bound(age, 0, MAX_AGE);

        vm.warp(START + MAX_AGE);
        feed.setAnswer(answer, block.timestamp - age);

        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.BadPrice.selector, answer));
        reader.latestPrice();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_expirationBoundaryAcrossUint256(int256 answer, uint256 updatedAt, uint256 maxAge) public {
        answer = bound(answer, 1, type(int256).max);
        updatedAt = bound(updatedAt, 1, type(uint256).max - 2);
        maxAge = bound(maxAge, 1, type(uint256).max - updatedAt - 1);
        uint256 expiresAt = updatedAt + maxAge;

        EthUsdReader r = new EthUsdReader(address(feed), maxAge);
        feed.setAnswer(answer, updatedAt);
        vm.warp(expiresAt);

        (uint256 price, uint256 returnedUpdatedAt) = r.latestPrice();
        assertEq(price, uint256(answer));
        assertEq(returnedUpdatedAt, updatedAt);

        vm.warp(expiresAt + 1);
        vm.expectRevert(abi.encodeWithSelector(EthUsdReader.StalePrice.selector, updatedAt));
        r.latestPrice();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_constructorStoresArguments(address aggregator_, uint256 maxAge_) public {
        vm.assume(aggregator_ != address(0));
        maxAge_ = bound(maxAge_, 1, type(uint256).max);

        EthUsdReader r = new EthUsdReader(aggregator_, maxAge_);
        assertEq(address(r.aggregator()), aggregator_);
        assertEq(r.maxAge(), maxAge_);
    }
}
