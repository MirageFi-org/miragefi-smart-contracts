// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {
    AggregatorV3Interface,
    IERC8056,
    IOraclePauseSource,
    IMarketStatusSource,
    IStreamAdapter
} from "../interfaces/IExternal.sol";

/// @notice Testnet stand-ins. Not for mainnet. Mint is open so anyone can obtain test balances.

contract MockERC20 is ERC20 {
    uint8 internal immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mimics a Robinhood Stock Token: ERC-20 with 18 decimals, ERC-8056 `uiMultiplier()` and a pause flag.
contract MockStockToken is ERC20, IERC8056, IOraclePauseSource, IMarketStatusSource {
    uint256 public multiplier = 1e18;
    bool public paused;
    uint8 public status = 1; // 1 regular, 2 extended, 5 closed

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function setOraclePaused(bool p) external {
        paused = p;
    }

    function setMarketStatus(uint8 s) external {
        status = s;
    }

    function uiMultiplier() external view override returns (uint256) {
        return multiplier;
    }

    function oraclePaused() external view override returns (bool) {
        return paused;
    }

    function marketStatus() external view override returns (uint8) {
        return status;
    }
}

contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public immutable dec;
    int256 public answer;
    uint256 public updatedAt;
    uint256 public startedAt;
    uint80 public round;

    constructor(uint8 decimals_, int256 initial) {
        dec = decimals_;
        answer = initial;
        updatedAt = block.timestamp;
        startedAt = block.timestamp;
        round = 1;
    }

    function decimals() external view override returns (uint8) {
        return dec;
    }

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
        round++;
    }

    function setWithTimestamps(int256 a, uint256 started, uint256 updated) external {
        answer = a;
        startedAt = started;
        updatedAt = updated;
        round++;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (round, answer, startedAt, updatedAt, round);
    }
}

/// @notice Returns a configurable price as if a Data Streams report had been verified.
contract MockStreamAdapter is IStreamAdapter {
    uint256 public price;

    function set(uint256 p) external {
        price = p;
    }

    function verify(address, bytes calldata) external view override returns (uint256, uint256) {
        return (price, block.timestamp);
    }
}
