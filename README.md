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
