// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
import './lib/Operator.sol';
import './lib/ERC20Burnable.sol';
contract NDFIL is ERC20Burnable, Operator {

    address public _team;
    uint256 maxTotalSupply = 5 * 1e26;

    constructor(address team) public ERC20('NDFIL', 'NDFIL') {
        _mint(msg.sender, 1e18);
        _team = team;
        _mint(team, 8933951 * 1e18);
    }

    function mint(uint256 amount) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(_team);
        require(maxTotalSupply >= totalSupply().add(amount), '!mint');
        _mint(_team, amount);
        uint256 balanceAfter = balanceOf(_team);
        return balanceAfter >= balanceBefore;
    }

    function burn(uint256 amount) public override onlyOperator {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }
}
