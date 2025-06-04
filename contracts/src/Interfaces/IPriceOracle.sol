//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPriceOracle {
    /**
     * @notice Returns the price of an asset in USD.
     * @param _asset The address of the asset.
     * @return price The price of the asset, scaled by 10^8 (e.g., price of 1.00 USD is 100000000).
     */
    function getAssetPrice(
        address _asset
    ) external view returns (uint256 price);

    /**
     * @notice Returns the number of decimals used for prices. Chainlink USD feeds usually use 8.
     */
    function getPriceDecimals() external pure returns (uint8);
}
