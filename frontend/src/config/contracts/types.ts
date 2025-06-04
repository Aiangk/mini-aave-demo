import { type Address } from 'viem';

// 资产数据类型定义
export type GetAssetDataReturnType = {
  aTokenAddress: Address;
  currentAnnualLiquidityRateRAY: bigint;
  currentAnnualVariableBorrowRateRAY: bigint;
  isSupported: boolean;
  totalLiquidity: bigint;
  totalBorrows: bigint;
  collateralFactor: bigint;
};

// 用户账户数据类型定义
export type GetUserAccountDataReturnType = {
  totalCollateralUSD: bigint;
  totalDebtUSD: bigint;
  availableBorrowsUSD: bigint;
  currentLiquidationThreshold: bigint;
  healthFactor: bigint;
};
