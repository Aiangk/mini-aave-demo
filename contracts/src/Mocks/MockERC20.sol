// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC20 is ERC20, Ownable {
    uint8 private _mockDecimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 tokenDecimals,
        uint256 initialSupply
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mockDecimals = tokenDecimals;
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply * (10 ** tokenDecimals));
        }
    }

    //重写decimals函数，返回mock的精度
    function decimals() public view virtual override returns (uint8) {
        return _mockDecimals;
    }

    function mint(address to, uint256 amountWithDecimals) public onlyOwner {
        //amountWithDecimals是已经带精度的数量
        _mint(to, amountWithDecimals);
    }

    function burn(address from, uint256 amountWithDecimals) public onlyOwner {
        //amountWithDecimals是已经带精度的数量
        _burn(from, amountWithDecimals);
    }
}
