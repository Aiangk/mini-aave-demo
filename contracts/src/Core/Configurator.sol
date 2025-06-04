// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {LendingPool} from './LendingPool.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol'; // For decimals()

//configurator 配置器
contract Configurator is Ownable {
  LendingPool public lendingPool;

  event LendingPoolSet(address indexed lendingPoolAddress);
  uint256 public constant PERCENTAGE_FACTOR = 1e4;

  constructor(address _lendingPoolAddress) Ownable(msg.sender) {
    if (_lendingPoolAddress != address(0)) {
      setLendingPool(_lendingPoolAddress);
    }
  }

  function setLendingPool(address _lendingPoolAddress) public onlyOwner {
    require(_lendingPoolAddress != address(0), 'Configurator: InvalidLendingPool address');
    lendingPool = LendingPool(_lendingPoolAddress);
    /* ILendingPool(_lendingPoolAddress) 这部分是将这个原始地址类型转换为一个 ILendingPool 接口类型的变量。Solidity 允许你将一个地址包装成一个接口类型，这样做是为了告诉编译器：“我相信在这个地址上部署的合约实现了 ILendingPool 接口中定义的所有函数。”*/
    emit LendingPoolSet(_lendingPoolAddress);
  }

  function addAsset(
    address _asset,
    uint256 _ltv,
    uint256 _liquidationThreshold,
    address _interestRateStrategy,
    uint256 _reserveFactor,
    uint256 _liquidationBonus
  ) external onlyOwner {
    require(_asset != address(0), 'Configurator: Invalid asset address');
    require(
      _interestRateStrategy != address(0),
      'Configurator: Invalid interest rate strategy address'
    );
    require(_liquidationBonus < PERCENTAGE_FACTOR / 2, 'Configurator: Liquidation bonus too high');
    //// LTV, LiquidationThreshold, ReserveFactor 都被检查过了，在LendingPool.configureAsset中。
    uint8 assetDecimals;
    try IERC20Metadata(_asset).decimals() returns (uint8 decimalsValue) {
      assetDecimals = decimalsValue;
    } catch {
      revert('Configurator: Could not fetch decimals for asset');
    }
    require(
      assetDecimals > 0 && assetDecimals <= 18,
      'Configurator: Invalid asset decimals (must be 1-18)'
    );

    lendingPool.configureAsset(
      _asset,
      true,
      assetDecimals,
      _ltv,
      _liquidationThreshold,
      _interestRateStrategy,
      _reserveFactor,
      _liquidationBonus
    );
  }

  function removeAsset(address _asset) external onlyOwner {
    require(_asset != address(0), 'Configurator: Invalid asset address');
    lendingPool.configureAsset(_asset, false, 0, 0, 0, address(0), 0, 0);
  }

  //单独用于更新清算奖励的函数
  function updateAssetLiquidationBonus(
    address _asset,
    uint256 _newLiquidationBonus
  ) external onlyOwner {
    require(_asset != address(0), 'Configurator: Invalid asset address');
    lendingPool.setAssetLiquidationBonus(_asset, _newLiquidationBonus);
  }

  // 更新资产的利率策略和储备因子
  function updateAssetInterestRateStrategy(
    address _asset,
    address _newStrategyAddress
  ) external onlyOwner {
    require(
      _asset != address(0) && _newStrategyAddress != address(0),
      'Configurator: Invalid new IR strategy address'
    );
    lendingPool.setAssetInterestRateStrategy(_asset, _newStrategyAddress);
  }

  function updateAssetReserveFactor(address _asset, uint256 _newReserveFactor) external onlyOwner {
    require(_asset != address(0), 'Configurator: Invalid asset address');
    // PERCENTAGE_FACTOR check is in LendingPool.setAssetReserveFactor
    lendingPool.setAssetReserveFactor(_asset, _newReserveFactor);
  }
}
