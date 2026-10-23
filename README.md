# EthUsdReader

A tiny, stateless Solidity contract that reads the ETH/USD price from a Chainlink price feed
and refuses a stale or non-positive answer. It has no token, no owner, no upgrade path and no
mutable storage.

## Contract

`src/EthUsdReader.sol`

| Item | Description |
|------|-------------|
| `constructor(address aggregator_, uint256 maxAge_)` | Stores the Chainlink aggregator (proxy) address and the maximum accepted answer age in seconds. Both are `immutable`. Reverts `ZeroAggregator()` / `ZeroMaxAge()` on a zero argument. Makes no external call. |
| `latestPrice() → (uint256 price, uint256 updatedAt)` | Calls `aggregator.latestRoundData()`. Reverts `StalePrice(updatedAt)` when `block.timestamp - updatedAt > maxAge`, then `BadPrice(answer)` when `answer <= 0`. Otherwise returns the answer (8 decimals for ETH/USD) and its update timestamp. |
| `aggregator()` / `maxAge()` | Public getters for the two immutables. |
| `DECIMALS` | Constant `8`, the decimals of the Chainlink ETH/USD feed. |

Behavioural details:

- An answer whose age is exactly `maxAge` is accepted; one second older is refused.
- A feed `updatedAt` of `0` (round never completed) is stale.
- A feed `updatedAt` in the future is treated as age zero; it never underflows.
- The staleness check runs before the sign check, so a stale and non-positive answer reports `StalePrice`.
- A revert inside the feed bubbles up unchanged. A target with no code reverts too.

## Deployment parameters

| Parameter | Mainnet value | Where it comes from |
|-----------|---------------|---------------------|
| `aggregator_` | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | Chainlink ETH/USD aggregator proxy on Ethereum mainnet, from the task brief and the pinned address reference. Confirmed live on 2026-10-23: has code, `decimals() == 8`, `description() == "ETH / USD"`. |
| `maxAge_` | `10800` (3 hours) | Chosen by the deployer. The mainnet ETH/USD feed heartbeat is 1 hour with a 0.5 % deviation threshold; three hours tolerates one missed heartbeat without accepting a day-old quote. Pick a tighter value if your consumer needs fresher data. |

`script/DeployEthUsdReader.s.sol` holds these as constants and passes them to `deploy(address, uint256)`,
which the tests call directly. `run()` only wraps `deploy` in a broadcast. No environment variables
are read anywhere. For another chain, substitute that chain's published Chainlink ETH/USD feed
address and verify it on-chain (`cast code`, `decimals()`, `description()`) before deploying.

The constructor takes 2 arguments, calls no contract and does not require the aggregator to have
code, so it can be deployed on an empty chain; the feed is checked on first use of `latestPrice()`.

## Assumptions

- **Feed semantics**: the aggregator implements Chainlink's `AggregatorV3Interface` and its
  `latestRoundData()` returns `updatedAt` as a Unix timestamp set by the chain on the update
  transaction. Only `answer` and `updatedAt` are used; `roundId`, `startedAt` and
  `answeredInRound` are ignored (the `answeredInRound` check is deprecated for OCR feeds).
- **Decimals**: `DECIMALS` is a constant `8` matching the ETH/USD feed. The constructor does
  not query the feed, so a deployer who points the reader at a feed with other decimals gets
  that feed's raw answer. The fork test asserts the live feed reports 8.
- **Trust**: the price is exactly what Chainlink reports. The contract only filters staleness
  and sign; it adds no bounds, no TWAP, no circuit breaker and no multi-oracle fallback.
  Chainlink feeds carry built-in min/max answer limits on some pairs; a market move beyond those
  limits returns the clamped limit, which this contract cannot detect.
- **Time**: `block.timestamp` is the chain's clock. On an L2 it is the sequencer's time and may
  lag; sequencer-uptime feeds are not consulted.

## Operational responsibilities

There is no owner and nothing to administer after deployment. The deployer is responsible for:

- choosing a `maxAge` that fits the feed's heartbeat on the target chain, and redeploying
  (the value is immutable) if Chainlink changes the heartbeat or the feed is deprecated;
- monitoring Chainlink's feed deprecation notices; a deprecated feed stops updating and every
  call will revert `StalePrice`, which is the intended fail-closed behaviour;
- verifying the source on the block explorer after deploy (`forge verify-contract`);
- treating this reader as one input, not a complete oracle, when it feeds anything that holds
  value. A separate adversarial review is needed before any value depends on it.

Callers should expect `latestPrice()` to revert during a feed outage and handle that at the
call site rather than catching and defaulting.

## Project layout

```
foundry.toml                      compiler pinned to solc 0.8.26, no ffi, no fs permissions
remappings.txt                    forge-std/ → lib/forge-std/src/
src/EthUsdReader.sol              the contract
src/interfaces/AggregatorV3Interface.sol
script/DeployEthUsdReader.s.sol   deploy script (constants + deploy(); run() broadcasts)
test/EthUsdReader.t.sol           unit and fuzz tests against a mock feed
test/EthUsdReader.fork.t.sol      mainnet fork tests against the live Chainlink feed
test/DeployEthUsdReader.t.sol     tests the deploy function directly
test/mocks/MockAggregatorV3.sol   controllable feed double
lib/forge-std/                    forge-std v1.9.7 vendored as plain files (no submodule)
```

## Build and test

```
forge build
forge test
forge fmt --check
```

The fork tests connect to the public endpoint named under `[rpc_endpoints]` in `foundry.toml`
and pin block `26252743`. When that endpoint cannot be reached (for example in an offline
verifier) they are skipped, not failed; the unit, fuzz and deploy tests run everywhere. To use
a different endpoint, edit the `mainnet` entry in `foundry.toml`. Tests read no environment
variables and pass in any order and in parallel.

Fork test coverage against the live feed: the feed address has code, reports 8 decimals and the
description `ETH / USD`; `latestPrice()` returns the feed's answer and `updatedAt` verbatim and
matches the values recorded at the pinned block; warping one second past `maxAge` reverts
`StalePrice`; a `maxAge` smaller than the current answer age reverts while an exact one passes;
and mocking the live feed's answer to `0` or `-5` reverts `BadPrice`.

## Security notes

Checked against the pinned security checklist: no owner or privileged function; no external call
in the constructor; no token handling, approvals or ETH; a single external `view` call with no
state change, so reentrancy does not apply; no `selfdestruct`, `delegatecall`, assembly, or
`abi.encodePacked`. Slither was not available on this machine; nothing in the source matches the
six rejecting detectors. Passing tests are not an audit.
