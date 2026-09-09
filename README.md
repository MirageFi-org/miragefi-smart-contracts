# MirageFi contracts

Smart contracts for MirageFi: a non-custodial swap venue for tokenized real-world assets on Robinhood Chain. Anchor vaults quote both sides of every market around the guarded Chainlink mid, block-size flow settles through signed RFQ maker quotes, and one router composes the two behind a single entry point, settled in USDG.

Built with Foundry for Robinhood Chain (chain ID 4663), an Arbitrum Nitro chain.

## Layout

```
src/
  SwapRouter.sol              sole trader entry point: eligibility, vault-versus-RFQ selection, two-leg composition
  AnchorVault.sol             one per market: oracle-anchored quoting, inventory skew, LP shares, in-kind withdrawal
  VaultFactory.sol            deploys vaults and is the registry the router resolves them from
  RfqSettlement.sol           EIP-712 maker quotes, nonce cancellation, atomic band-checked settlement
  OracleRouter.sol            Chainlink feeds and streams with session, staleness, move-cap and sequencer guards
  EligibilityRegistry.sol     role checks through a swappable policy adapter
  adapters/NativeAttestationAdapter.sol   self-contained attestation store with EAS semantics
  ParamController.sol         every tunable parameter behind a timelock; guardian can only pause swaps
  FeeCollector.sol            receives the itemised swap fees, RFQ fees and the protocol spread share
  libraries/                  Types (quotes, breakdowns, roles and constants)
  interfaces/                 protocol and external (Chainlink, ERC-8056) interfaces
  mocks/                      local-development stand-ins: USDG, Stock Token, aggregator, stream adapter
script/Deploy.s.sol           full deployment and configuration; opens the launch market
script/Seed.s.sol             seeds a fresh testnet deployment with liquidity and a first pair of fills
script/Activity.s.sol         adds a round of multi-wallet activity (deposits, a withdrawal, a batch of swaps)
test/                         Foundry suite: vault accounting, swap pricing, regimes and halts, RFQ, governance
deployments/                  addresses written by the deploy script, one JSON file per chain ID
```

## Deployments

### Robinhood Chain testnet (chain ID 46630)

Deployed 9 September 2026 from `0x3750a184c4BdE99E129F51a4e9a853DDD86257D0`, which is also the bootstrap owner, guardian and attestation issuer on testnet. All twelve contracts are verified on [Blockscout](https://explorer.testnet.chain.robinhood.com). External dependencies are mocks: the deploy script stands in its own USDG, NVDAx stock token and Chainlink aggregator (NVDAx at 176.40 USDG). The full list is in `deployments/46630.json`.

The launch vault is seeded with roughly 1,000,000 USDG of balanced liquidity and carries deposits, a withdrawal and a batch of fills from the seed and activity scripts, so the explorer and the platform have real history to show.

| Contract | Address |
| --- | --- |
| SwapRouter | [`0xF03c1F25A312761df9fBA7a1c0f929628286584a`](https://explorer.testnet.chain.robinhood.com/address/0xF03c1F25A312761df9fBA7a1c0f929628286584a) |
| RfqSettlement | [`0xf97941aaA5490Ad8d2e45A62f2662d7aF252A9Ef`](https://explorer.testnet.chain.robinhood.com/address/0xf97941aaA5490Ad8d2e45A62f2662d7aF252A9Ef) |
| VaultFactory | [`0xEa43913350cd07aEFE87E38FeD7AAe4d636F5081`](https://explorer.testnet.chain.robinhood.com/address/0xEa43913350cd07aEFE87E38FeD7AAe4d636F5081) |
| AnchorVault (NVDAx / USDG, `zvNVDAx`) | [`0xC8035f1F13ADd6b109d22B46f0D7eA21dC51C83f`](https://explorer.testnet.chain.robinhood.com/address/0xC8035f1F13ADd6b109d22B46f0D7eA21dC51C83f) |
| OracleRouter | [`0x1B8247dCda39b1492A5D927861624CF942B01dAd`](https://explorer.testnet.chain.robinhood.com/address/0x1B8247dCda39b1492A5D927861624CF942B01dAd) |
| EligibilityRegistry | [`0xb9B45C8A0108BB8D87B94FBa5B11E743fb36Ec5c`](https://explorer.testnet.chain.robinhood.com/address/0xb9B45C8A0108BB8D87B94FBa5B11E743fb36Ec5c) |
| NativeAttestationAdapter | [`0x315479a50eA40bF2ef5536cF8563df715e215Dc3`](https://explorer.testnet.chain.robinhood.com/address/0x315479a50eA40bF2ef5536cF8563df715e215Dc3) |
| ParamController | [`0x330537882A0275756D1021c6b4E96DE9A1dC72F2`](https://explorer.testnet.chain.robinhood.com/address/0x330537882A0275756D1021c6b4E96DE9A1dC72F2) |
| FeeCollector | [`0x447329EfCEB5a4898949E19fB5D635C396280f02`](https://explorer.testnet.chain.robinhood.com/address/0x447329EfCEB5a4898949E19fB5D635C396280f02) |
| USDG (mock) | [`0x69ea3faD03c7f52Cce6D8f2571EA40507Dc480Fb`](https://explorer.testnet.chain.robinhood.com/address/0x69ea3faD03c7f52Cce6D8f2571EA40507Dc480Fb) |
| NVDAx stock token (mock) | [`0x049D8363Ac46cd065365568E18644f5eba37BcD5`](https://explorer.testnet.chain.robinhood.com/address/0x049D8363Ac46cd065365568E18644f5eba37BcD5) |
| NVDAx / USD aggregator (mock) | [`0xE0F83ca2860e554207f680183646B904FfE8F100`](https://explorer.testnet.chain.robinhood.com/address/0xE0F83ca2860e554207f680183646B904FfE8F100) |

The testnet deployment runs with the documented launch parameters, `TIMELOCK_DELAY=3600` and `FINISH_BOOTSTRAP=false`, so the deployer can still call the `ParamController` setters directly. The deployer is attested for every role (trader, LP, maker, relayer) so the flows can be exercised from that account straight away.

### Robinhood Chain mainnet (chain ID 4663)

Not yet deployed. Mainnet requires the live `USDG`, `STOCK_TOKEN`, `STOCK_FEED` and `SEQUENCER_FEED` addresses; the script refuses to deploy mocks on chain ID 4663.

## How a swap settles

1. The trader calls `SwapRouter.swapExactIn` with the pair, an exact input, a minimum output and a deadline, optionally attaching a signed maker quote.
2. The router checks the trader's `TRADER` attestation, re-derives the anchor vault's price from oracle and vault state in the same transaction, verifies the maker quote's signature if one was attached, and settles whichever venue outputs more.
3. The vault prices from the formula: guarded Chainlink mid, tier half-spread times the session multiplier, signed inventory skew, itemised fee. Every fill emits its full breakdown, and nothing can settle outside the tier's oracle band on either venue.
4. Token-to-token swaps run as two atomic legs through USDG; if either leg cannot clear inside its market's guards, both revert.

## Quick start

```bash
forge soldeer install     # pulls forge-std and OpenZeppelin into dependencies/
forge build
forge test -vv
```

Dependencies are managed by soldeer (no git submodules). Solidity 0.8.26, Cancun EVM, via-IR.

## Deploying

1. Copy `.env.example` to `.env` and fill in `PRIVATE_KEY`, the RPC URL for the target chain (`ROBINHOOD_TESTNET_RPC` or `ROBINHOOD_RPC`; the official URLs are listed at docs.robinhood.com/chain) and the matching Blockscout API URL for verification.
2. Set `USDG`, `STOCK_TOKEN` and `STOCK_FEED` to the live addresses. On a local Anvil chain or the testnet they can be left blank to deploy mocks.
3. Deploy. The RPC alias is `robinhood_testnet` for chain ID 46630 and `robinhood` for mainnet:

```bash
source .env
forge script script/Deploy.s.sol --rpc-url robinhood_testnet --broadcast --verify
```

The script writes `deployments/<chainId>.json` with every address, opens the launch market and sets the documented launch parameters (Tier A: 10 bps half-spread, 75 bps band, 50,000 USDG clip; x1.5 extended and x3 closed session multipliers; 2 bps fees and a 10% spread share). Set `GOV` to hand ownership to the governance multisig and `FINISH_BOOTSTRAP=true` to lock parameters to the timelock. Whenever mocks are deployed and the deployer is the attestation issuer, the deployer attests itself for every role so the flows can be exercised immediately.

`--verify` covers the eleven contracts the script deploys directly. The `AnchorVault` is deployed by the factory, so forge cannot recover its constructor arguments and Blockscout rejects the automatic submission. Verify it by hand with the addresses from the deployments file:

```bash
ARGS=$(cast abi-encode "constructor(address,address,address,address,address,address,string,string)" \
  $PARAM_CONTROLLER $ELIGIBILITY_REGISTRY $ORACLE_ROUTER $FEE_COLLECTOR $USDG $STOCK_TOKEN \
  "MirageFi NVDAx Vault" "zvNVDAx")
forge verify-contract $ANCHOR_VAULT src/AnchorVault.sol:AnchorVault --chain 46630 \
  --verifier blockscout --verifier-url "$ROBINHOOD_TESTNET_BLOCKSCOUT_API" --constructor-args "$ARGS" --watch
```

### Seeding a testnet deployment

Both scripts read `deployments/<chainId>.json` and need the mock tokens, so they only apply to testnet or a local chain.

```bash
forge script script/Seed.s.sol --rpc-url robinhood_testnet --broadcast
forge script script/Activity.s.sol --rpc-url robinhood_testnet --broadcast --slow
```

`Seed` mints balances for the deployer, deposits 500,000 USDG per side into the launch vault and puts one buy and one sell through the router. `Activity` derives two LP and five trader wallets from the deployer key, funds them with a small gas stipend, attests them, and runs two deposits, a partial withdrawal and twenty swaps in both directions. Every `Activity` run adds on top of the existing state; set `ROUND` to a new value each time so the trade sizes differ. Budget about 0.003 ETH on the deployer for a deploy plus one round of each, most of it the gas stipends.

## Governance model

- `ParamController` starts in bootstrap mode: the owner can call setters directly. `finishBootstrap()` is irreversible and routes every change through `schedule` / `execute` with the configured delay.
- The guardian can only pause swaps. Nothing can pause deposits, withdrawals or RFQ cancellation.
- `SwapRouter`, `AnchorVault`, `VaultFactory` and `RfqSettlement` have no proxy and no admin. Improvements ship as new deployments that LPs migrate to by choice.

## Key invariants

- No fill clears outside the tier's oracle band, from a vault or a maker, in any regime, under any parameter set the controller accepts.
- Vault withdrawal is pro-rata in kind and works in every state: halted, guardian-paused, market retired, attestation expired. Nothing can trap LP funds.
- Value per share never decreases from a swap; mint and burn rounding always favours the vault.
- A fill may not leave a vault outside its inventory band, and the preview and the fill agree exactly, so the harmful side goes one-sided instead of absorbing unbounded inventory.
- Every market is priced with the feed configured for the exact token in the vault, never a wrapper or a derived rate.
- Quotes are itemised on-chain: the fill event carries mid, spread, skew and fee, matching what was quoted.

## Notes for integrators

- Approvals run against the router (traders) and `RfqSettlement` (makers); Permit2 and ERC-4337 batching sit above these contracts rather than inside them.
- Deposits price the incoming assets at the guarded mid, so they revert while a market is halted; withdrawals read no oracle at all and never revert on market state.
- `AnchorVault.quoteSwap` is the exact preview: it reverts while the market is halted, and the router treats that as "no vault quote" so RFQ can still carry the market.
- A feed print further than the move cap from a recent checkpoint halts the market in the block it lands, for previews, fills and RFQ settlement alike. `OracleRouter.refresh` is permissionless: calling it on a halted market writes the pause so it outlives the move-cap window, and only `resume` from governance clears it.

## Security

The security programme (testing, audits, bounty and disclosure) is described in `docs/architecture/security.md`. Report vulnerabilities to security@miragefi.org rather than in public issues.
