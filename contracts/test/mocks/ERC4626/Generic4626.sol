// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.14;

import {BaseStrategy, ERC20} from "../../../BaseStrategy.sol";

contract Generic4626 is BaseStrategy {
    constructor(ERC20 _asset) BaseStrategy(_asset, "name", "symbol") {}

    function _invest(uint256 _amount) internal override returns (uint256) {
        return _amount;
    }

    function _withdraw(uint256 _amount) internal override returns (uint256) {
        return _amount;
    }

    function _totalInvested() internal override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}
