// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IParamController} from "./interfaces/IParamController.sol";

/// @title FeeCollector
/// @notice Receives the itemised swap fees, RFQ fees and the protocol's spread share. Withdrawal is
///         controlled by the ParamController owner until the governance module takes over allocation.
contract FeeCollector {
    using SafeERC20 for IERC20;

    IParamController public immutable params;

    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    error NotGovernance();
    error ZeroAddress();

    constructor(IParamController params_) {
        if (address(params_) == address(0)) revert ZeroAddress();
        params = params_;
    }

    function withdraw(IERC20 token, address to, uint256 amount) external {
        if (msg.sender != params.owner()) revert NotGovernance();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }
}
