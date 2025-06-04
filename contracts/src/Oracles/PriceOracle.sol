//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPriceOracle} from "../Interfaces/IPriceOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PriceOracle is IPriceOracle, Ownable {
    mapping(address => uint256) private assetPrices;
    uint8 public constant PRICE_DECIMALS = 8;

    //PRICE_DECIMALS 价格小数位数

    constructor() Ownable(msg.sender) {}

    function setAssetPrice(address _asset, uint256 _price) external onlyOwner {
        require(_asset != address(0), "PriceOracle: Invalid asset address");
        assetPrices[_asset] = _price;
    }

    function getAssetPrice(
        address _asset
    ) external view returns (uint256 price) {
        return assetPrices[_asset];
    }

    function getPriceDecimals() external pure returns (uint8) {
        return PRICE_DECIMALS;
    }
}
