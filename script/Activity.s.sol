// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {NativeAttestationAdapter} from "../src/adapters/NativeAttestationAdapter.sol";
import {Roles, Types} from "../src/libraries/Types.sol";
import {MockERC20, MockStockToken, MockAggregatorV3} from "../src/mocks/Mocks.sol";

/// @title Activity
/// @notice Adds a round of activity to an already seeded testnet deployment: a handful of trader and LP
///         wallets derived from the deployer key, funded with gas and attested by the deployer, put a batch
///         of swaps through the router in both directions, and two LPs deposit while one withdraws part
///         of its position. Existing liquidity is left in place; every run adds on top.
/// @dev Reads deployments/<chainId>.json written by Deploy.s.sol. Actors send in sequence, so run with --slow:
///        forge script script/Activity.s.sol --rpc-url robinhood_testnet --broadcast --slow
///      ROUND (optional, default 1) salts the trade sizes so repeated runs do not print identical fills.
contract Activity is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant GAS_STIPEND = 0.0003 ether;

    struct Actor {
        string name;
        uint256 pk;
        address addr;
    }

    struct Ctx {
        MockERC20 usdg;
        MockStockToken stock;
        MockAggregatorV3 feed;
        AnchorVault vault;
        SwapRouter router;
        NativeAttestationAdapter attestations;
        uint256 mid; // quote units (6 dec) per whole token
        uint256 round;
    }

    Ctx internal c;
    Actor internal deployer;
    Actor[] internal lps;
    Actor[] internal traders;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        deployer = Actor("deployer", pk, vm.addr(pk));

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        c.usdg = MockERC20(vm.parseJsonAddress(json, ".USDG"));
        c.stock = MockStockToken(vm.parseJsonAddress(json, ".StockToken"));
        c.feed = MockAggregatorV3(vm.parseJsonAddress(json, ".StockFeed"));
        c.vault = AnchorVault(vm.parseJsonAddress(json, ".AnchorVault"));
        c.router = SwapRouter(vm.parseJsonAddress(json, ".SwapRouter"));
        c.attestations = NativeAttestationAdapter(vm.parseJsonAddress(json, ".NativeAttestationAdapter"));
        c.mid = uint256(c.feed.answer()) / 100;
        c.round = vm.envOr("ROUND", uint256(1));

        lps.push(_derive(pk, "lp-1"));
        lps.push(_derive(pk, "lp-2"));
        traders.push(_derive(pk, "trader-1"));
        traders.push(_derive(pk, "trader-2"));
        traders.push(_derive(pk, "trader-3"));
        traders.push(_derive(pk, "trader-4"));
        traders.push(_derive(pk, "trader-5"));

        _prepare();
        _liquidity();
        _trades();

        console2.log("Vault", address(c.vault));
        console2.log("TVL (USDG, 6 dec)", c.vault.totalValue());
        console2.log("Token-side inventory (bps)", c.vault.inventoryRatioBps());
    }

    // ---------------------------------------------------------------------
    // Fresh oracle round, gas and attestations for every actor, balances and router approvals
    // ---------------------------------------------------------------------

    function _prepare() internal {
        vm.startBroadcast(deployer.pk);
        c.feed.set(c.feed.answer());
        for (uint256 i; i < lps.length; i++) _fund(lps[i]);
        for (uint256 i; i < traders.length; i++) _fund(traders[i]);
        vm.stopBroadcast();

        for (uint256 i; i < lps.length; i++) _attest(lps[i], Roles.LP, 3);
        for (uint256 i; i < traders.length; i++) {
            _attest(traders[i], Roles.TRADER, 2);
            _mint(traders[i], 600e6, _tokens(600e6));
            vm.startBroadcast(traders[i].pk);
            if (c.usdg.allowance(traders[i].addr, address(c.router)) == 0) {
                c.usdg.approve(address(c.router), type(uint256).max);
                c.stock.approve(address(c.router), type(uint256).max);
            }
            vm.stopBroadcast();
        }
    }

    // ---------------------------------------------------------------------
    // LP side: two deposits of different shapes, then a partial withdrawal from an earlier position
    // ---------------------------------------------------------------------

    function _liquidity() internal {
        _deposit(lps[0], 60e6, _tokens(60e6));
        _deposit(lps[1], 0, _tokens(80e6));

        uint256 shares = c.vault.balanceOf(lps[0].addr);
        vm.startBroadcast(lps[0].pk);
        c.vault.withdraw(shares / 5, lps[0].addr);
        vm.stopBroadcast();
        console2.log(lps[0].name, "withdrew shares", shares / 5);
    }

    function _deposit(Actor memory a, uint256 quoteAmount, uint256 tokenAmount) internal {
        _mint(a, quoteAmount, tokenAmount);
        vm.startBroadcast(a.pk);
        if (quoteAmount != 0) c.usdg.approve(address(c.vault), quoteAmount);
        if (tokenAmount != 0) c.stock.approve(address(c.vault), tokenAmount);
        c.vault.deposit(quoteAmount, tokenAmount, 0, a.addr);
        vm.stopBroadcast();
        console2.log(a.name, "deposited (quote, token)", quoteAmount, tokenAmount);
    }

    // ---------------------------------------------------------------------
    // Trading: twenty fills, sizes salted by ROUND, alternating enough to stay inside the inventory band
    // ---------------------------------------------------------------------

    function _trades() internal {
        // Base sizes in whole USDG; sells are expressed as the same notional converted to tokens.
        uint8[20] memory base = [125, 48, 190, 72, 35, 160, 18, 88, 95, 140, 66, 12, 110, 175, 42, 96, 130, 28, 150, 58];
        bool[20] memory isBuy = [
            true, true, false, true, false, true, true, false, false, true, false, true, false, true, false, false, true, false, true, false
        ];
        for (uint256 i; i < base.length; i++) {
            // Vary each size by up to +-15% from the round so repeated runs print different fills.
            uint256 jitter = uint256(keccak256(abi.encodePacked(c.round, i))) % 31;
            uint256 notional = uint256(base[i]) * 1e6 * (85 + jitter) / 100;
            Actor memory t = traders[(i + c.round) % traders.length];
            if (isBuy[i]) _buy(t, notional);
            else _sell(t, _tokens(notional));
        }
    }

    function _buy(Actor memory a, uint256 quoteIn) internal {
        _swap(a, address(c.usdg), address(c.stock), quoteIn);
    }

    function _sell(Actor memory a, uint256 tokenIn) internal {
        _swap(a, address(c.stock), address(c.usdg), tokenIn);
    }

    function _swap(Actor memory a, address tokenIn, address tokenOut, uint256 amountIn) internal {
        Types.MakerQuote memory none;
        vm.startBroadcast(a.pk);
        uint256 out = c.router.swapExactIn(
            SwapRouter.SwapParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                amountIn: amountIn,
                minAmountOut: 0,
                to: address(0),
                deadline: block.timestamp + 30 minutes,
                quote: none,
                quoteSig: ""
            })
        );
        vm.stopBroadcast();
        console2.log(a.name, tokenIn == address(c.usdg) ? "bought, out:" : "sold, out:", out);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _derive(uint256 pk, string memory label) internal pure returns (Actor memory) {
        uint256 k = uint256(keccak256(abi.encodePacked(pk, "miragefi.seed.", label))) % (SECP256K1_N - 1) + 1;
        return Actor(label, k, vm.addr(k));
    }

    function _tokens(uint256 quoteValue) internal view returns (uint256) {
        return quoteValue * 1e18 / c.mid;
    }

    function _fund(Actor memory a) internal {
        if (a.addr.balance >= GAS_STIPEND / 2) return;
        (bool ok,) = a.addr.call{value: GAS_STIPEND}("");
        require(ok, "gas transfer failed");
    }

    function _attest(Actor memory a, bytes32 role, uint8 investorClass) internal {
        if (c.attestations.isEligible(a.addr, role)) return;
        vm.startBroadcast(deployer.pk);
        c.attestations.attest(a.addr, role, "LT", investorClass, uint64(block.timestamp + 365 days));
        vm.stopBroadcast();
    }

    function _mint(Actor memory a, uint256 quoteAmount, uint256 tokenAmount) internal {
        vm.startBroadcast(deployer.pk);
        if (quoteAmount != 0) c.usdg.mint(a.addr, quoteAmount);
        if (tokenAmount != 0) c.stock.mint(a.addr, tokenAmount);
        vm.stopBroadcast();
    }
}
