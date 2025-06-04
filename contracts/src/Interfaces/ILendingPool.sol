// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILendingPool {
  //专门负责返回给前端用的数据结构体
  struct AssetDataReturn {
    bool isSupported;
    uint8 decimals;
    uint256 ltv;
    uint256 liquidationThreshold;
    address interestRateStrategy;
    uint256 reserveFactor;
    uint256 liquidationBonus;
    uint256 liquidityIndex;
    uint256 variableBorrowIndex;
    uint256 lastUpdateTimestamp;
    uint256 totalScaledDeposits;
    uint256 totalScaledVariableBorrows;
    uint256 currentTotalReserves;
    address aTokenAddress;
    uint256 currentAnnualLiquidityRateRAY;
    uint256 currentAnnualVariableBorrowRateRAY;
  }

  event Deposited(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event AssetConfigured(
    address indexed asset,
    bool isSupported,
    uint8 decimals, //资产自己的decimals
    uint256 ltv,
    uint256 liquidationThreshold,
    address interestRateStrategy,
    uint256 reserveFactor,
    uint256 liquidationBonus
  );

  event LiquidationCall(
    address indexed collateralAsset, //被清算的抵押品资产
    address indexed debtAsset,
    address indexed user,
    uint256 debtToCover,
    uint256 liquidatedCollateralAmount,
    address liquidator,
    bool receiveUnderlyingCollateral,
    uint256 timestamp
  );

  event Withdrawn(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event Borrowed(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event Repaid(
    address indexed asset,
    address indexed userToRepayFor,
    address indexed repayer,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event ReserveFactorUpdated(address indexed asset, uint256 newReserveFactor);
  event InterestRateStrategyUpdated(address indexed asset, address newStrategyAddress);

  event ReservesCollected(
    address indexed asset,
    address indexed reserveCollector,
    uint256 amountCollected
  );

  event FlashLoan(
    address indexed targetReceiver, // 接收闪电贷的合约地址
    address indexed initiator, // 发起闪电贷的原始调用者
    address indexed asset, // 借出的资产
    uint256 amount, // 借出的数量
    uint256 fee, // 支付的手续费
    uint256 timestamp
  );

  // 保留一个函数用于对比
  function getAssetData(address _asset) external view returns (AssetDataReturn memory assetData);

  function deposit(address _asset, uint256 _amount) external;

  function withdraw(address asset, uint256 amount) external;

  function borrow(address _assetToBorrow, uint256 _amountToBorrow) external;

  function repay(address _assetToRepay, uint256 _amountToRepay) external;

  function flashLoan(
    address _receiverAddress,
    address _asset,
    uint256 _amount,
    bytes calldata _params
  ) external;

  function liquidationCall(
    address _collateralAsset,
    address _debtAsset,
    address _userToLiquidate,
    uint256 _debtToCoverInUnderlying,
    bool _receiveUnderlyingCollateral
  ) external;

  // Admin functions (callable by Configurator) 配置器
  // 资产配置分析
  function configureAsset(
    address _asset,
    bool _isSupported,
    uint8 _assetDecimals,
    uint256 _ltv,
    uint256 _liquidationThreshold,
    address _interestRateStrategy,
    uint256 _reserveFactor,
    uint256 _liquidationBonus
  ) external;

  function setAssetLiquidationBonus(address _asset, uint256 _newLiquidationBonus) external;

  function setAssetInterestRateStrategy(address _asset, address _newStrategyAddress) external;

  //New View Functions for Phase 3

  //获取用户总债务
  function getUserTotalDebtUSD(address _user) external view returns (uint256 totalDebtUSD);

  //获取用户总借出额度
  function getUserBorrowPowerUSD(
    address _user
  ) external view returns (uint256 totalBorrowingPowerUSD);

  //获取用户可借出额度
  function getUserAvailableBorrowsUSD(
    address _user
  ) external view returns (uint256 availableBorrowsUSD);

  //获取用户健康因子
  function calculateHealthFactor(address _user) external view returns (uint256 healthFactor);

  // HF = (TotalCollateralUSD_Effective / TotalDebtUSD) * 10^18
  // TotalCollateralUSD_Effective = sum(collateral_usd * liquidation_threshold)

  function getFlashLoanFeePercentage() external view returns (uint256);

  // 例如返回 9 代表 0.09%

  function getUserTotalCollateralUSD(
    address _user
  ) external view returns (uint256 totalCollateralUSD);

  function getAssetPrice(address _asset) external view returns (uint256);

  function getPriceOracle() external view returns (address);

  function getSupportedAssets() external view returns (address[] memory);

  function getEffectiveUserDeposit(address _asset, address _user) external view returns (uint256); // 用户实际存款 (本金+利息)

  function getScaledUserDeposit(address _asset, address _user) external view returns (uint256); // 用户缩放存款

  function getEffectiveUserBorrowBalance(
    address _asset,
    address _user
  ) external view returns (uint256); // 用户实际借款 (本金+利息)

  function getScaledUserBorrowBalance(
    address _asset,
    address _user
  ) external view returns (uint256); // 用户缩放借款

  function getCurrentTotalActualDeposits(address _asset) external view returns (uint256); // 池中某资产实际总存款

  function getCurrentTotalActualBorrows(address _asset) external view returns (uint256); // 池中某资产实际总借款
}
