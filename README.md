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
