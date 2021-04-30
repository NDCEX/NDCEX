// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import './lib/Operator.sol';
import './lib/ERC20Burnable.sol';

contract NDCEX is ERC20Burnable, Operator {

    constructor(address mining, address lab, address founation, address investment)
    public ERC20('NDCEX', 'NDCEX') {
        _mint(msg.sender, 1e18);
        _mint(mining, 79_999_999 * 1e18);
        _mint(lab, 10_000_000 * 1e18);
        _mint(founation, 5_000_000 * 1e18);
        _mint(investment, 5_000_000 * 1e18);
    }

    // function mint(address recipient, uint256 amount) private onlyOperator returns (bool) {
    //     uint256 balanceBefore = balanceOf(recipient);
    //     _mint(recipient, amount);
    //     uint256 balanceAfter = balanceOf(recipient);
    //     return balanceAfter >= balanceBefore;
    // }

    function burn(uint256 amount) public override onlyOperator {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }
}
