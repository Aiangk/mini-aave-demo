import type { Address } from 'viem';

export interface GetAssetDataReturnType {
  // 注意：现在是 interface 或 type object
  isSupported: boolean;
  decimals: number;
  ltv: bigint;
  liquidationThreshold: bigint;
  interestRateStrategy: string; // address
  reserveFactor: bigint;
  liquidationBonus: bigint;
  liquidityIndex: bigint;
  variableBorrowIndex: bigint;
  lastUpdateTimestamp: bigint;
  totalScaledDeposits: bigint;
  totalScaledVariableBorrows: bigint;
  currentTotalReserves: bigint;
  aTokenAddress: string; // address
  currentAnnualLiquidityRateRAY: bigint;
  currentAnnualVariableBorrowRateRAY: bigint;
}
export type TransactionType =
  | 'Deposit'
  | 'Withdraw'
  | 'Borrow'
  | 'Repay'
  | 'Approval'; // 可以根据需要扩展

export interface TransactionHistoryEntry {
  id: string; // 通常是交易哈希
  type: TransactionType;
  assetSymbol: string; // 例如 'mUSDC'
  assetAddress: Address;
  amount: bigint; // 底层资产的金额 (最小单位)
  amountFormatted: string; // 格式化后的金额
  timestamp: bigint; // 区块时间戳
  dateFormatted: string; // 格式化后的日期时间
  txHash: Address;
}
// return
//       AssetDataReturn({
//         isSupported: assetInfo.isSupported,
//         decimals: assetInfo.decimals,
//         ltv: assetInfo.ltv,
//         liquidationThreshold: assetInfo.liquidationThreshold,
//         interestRateStrategy: assetInfo.interestRateStrategy,
//         reserveFactor: assetInfo.reserveFactor,
//         liquidationBonus: assetInfo.liquidationBonus,
//         liquidityIndex: assetInfo.liquidityIndex,
//         variableBorrowIndex: assetInfo.variableBorrowIndex,
//         lastUpdateTimestamp: assetInfo.lastUpdateTimestamp,
//         totalScaledDeposits: assetInfo.totalScaledDeposits,
//         totalScaledVariableBorrows: assetInfo.totalScaledVariableBorrows,
//         currentTotalReserves: assetInfo.currentTotalReserves,
//         aTokenAddress: assetInfo.aTokenAddress,
//         currentAnnualLiquidityRateRAY: fetchedAnnualLiquidityRateRAY,
//         currentAnnualVariableBorrowRateRAY: fetchedAnnualVariableBorrowRateRAY
//       });
