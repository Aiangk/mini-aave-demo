import React, { useMemo } from 'react';
import { useAccount, useReadContract, useReadContracts } from 'wagmi';
import { formatUnits, type Address, type Abi } from 'viem';

import {
  LendingPoolContractConfig,
  type AssetConfig,
  SUPPORTED_ASSETS_CONFIG,
} from '@/config/contracts';
import { type GetAssetDataReturnType } from '@/config/contracts/index';
import styles from './UserAccountOverview.module.css';
import { getErrorMessage } from '@/utils/errors';
import { formatDisplayNumber, DEFAULT_TOKEN_DISPLAY_DECIMALS, formatPercentage } from '@/utils/formatters'; 

const ORACLE_PRICE_DECIMALS = 8;
const RAY_BI = 10n ** 27n;
const BASIS_POINTS_BI = 10000n;
const USD_DISPLAY_DECIMALS = 2; // 美元金额显示的小数位数


// 健康因子阈值定义
const DANGER_HF_THRESHOLD = 1.1;
const WARNING_HF_THRESHOLD = 1.5;

interface UserAssetDetail extends AssetConfig {
  currentAnnualLiquidityRateRAY?: bigint;
  currentAnnualVariableBorrowRateRAY?: bigint;
  assetPriceUSD?: bigint;
  userSupplyAmount?: bigint;
  userBorrowAmount?: bigint;
}

interface HealthStatus {
  level: 'safe' | 'warning' | 'danger' | 'nodata' | 'nodebt';
  message: string;
  className: string;
}


function UserAccountOverview() {
  const { address: userAddress, isConnected } = useAccount();

  // 1. 获取全局用户账户数据 (与之前相同)
  const {
    data: totalCollateralUSD,
    isLoading: isLoadingTotalCollateralUSD,
    error: errorTotalCollateralUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserTotalCollateralUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as { data: bigint | undefined; isLoading: boolean; error: Error | null };

  const {
    data: totalDebtUSD,
    isLoading: isLoadingTotalDebtUSD,
    error: errorTotalDebtUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserTotalDebtUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as { data: bigint | undefined; isLoading: boolean; error: Error | null };

  const {
    data: availableBorrowsUSD,
    isLoading: isLoadingAvailableBorrowsUSD,
    error: errorAvailableBorrowsUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserAvailableBorrowsUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as { data: bigint | undefined; isLoading: boolean; error: Error | null };

  const {
    data: healthFactor,
    isLoading: isLoadingHealthFactor,
    error: errorHealthFactor,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'calculateHealthFactor',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as { data: bigint | undefined; isLoading: boolean; error: Error | null };

  const {
    data: supportedAssetsList,
    isLoading: isLoadingSupportedAssets,
    error: errorSupportedAssets,
  } = useReadContract({
    ...LendingPoolContractConfig,
    functionName: 'getSupportedAssets',
    query: { enabled: isConnected },
  }) as {
    data: Address[] | undefined;
    isLoading: boolean;
    error: Error | null;
  };

  const contractsToRead = useMemo(() => {
    if (!supportedAssetsList || !userAddress) return [];
    return supportedAssetsList.flatMap((assetAddress) => {
      const assetConfig = SUPPORTED_ASSETS_CONFIG.find(
        (a) => a.underlyingAddress.toLowerCase() === assetAddress.toLowerCase()
      );
      if (!assetConfig) return [];
      return [
        {
          address: LendingPoolContractConfig.address,
          abi: LendingPoolContractConfig.abi as Abi,
          functionName: 'getAssetPrice',
          args: [assetAddress] as const,
        },
        {
          address: LendingPoolContractConfig.address,
          abi: LendingPoolContractConfig.abi as Abi,
          functionName: 'getEffectiveUserDeposit',
          args: [assetAddress, userAddress] as const,
        },
        {
          address: LendingPoolContractConfig.address,
          abi: LendingPoolContractConfig.abi as Abi,
          functionName: 'getEffectiveUserBorrowBalance',
          args: [assetAddress, userAddress] as const,
        },
        {
          address: LendingPoolContractConfig.address,
          abi: LendingPoolContractConfig.abi as Abi,
          functionName: 'getAssetData',
          args: [assetAddress] as const,
        },
      ];
    });
  }, [supportedAssetsList, userAddress]);

  const {
    data: batchAssetsData,
    isLoading: isLoadingBatchAssetsData,
    error: errorBatchAssetsData,
  } = useReadContracts({
    contracts: contractsToRead,
    query: {
      enabled:
        isConnected &&
        !!userAddress &&
        !!supportedAssetsList &&
        supportedAssetsList.length > 0 &&
        contractsToRead.length > 0,
    },
  });

  const userAssetsDetails = useMemo((): UserAssetDetail[] => {
    if (
      !batchAssetsData ||
      !supportedAssetsList ||
      batchAssetsData.length === 0
    )
      return [];
    const details: UserAssetDetail[] = [];
    for (let i = 0; i < supportedAssetsList.length; i++) {
      const assetAddress = supportedAssetsList[i];
      const assetConfig = SUPPORTED_ASSETS_CONFIG.find(
        (a) => a.underlyingAddress.toLowerCase() === assetAddress.toLowerCase()
      );
      if (!assetConfig) continue;
      const priceResult = batchAssetsData[i * 4];
      const depositResult = batchAssetsData[i * 4 + 1];
      const borrowResult = batchAssetsData[i * 4 + 2];
      const assetDataResult = batchAssetsData[i * 4 + 3];
      if (
        priceResult?.status === 'success' &&
        depositResult?.status === 'success' &&
        borrowResult?.status === 'success' &&
        assetDataResult?.status === 'success'
      ) {
        const assetData = assetDataResult.result as
          | GetAssetDataReturnType
          | undefined;
        details.push({
          ...assetConfig,
          assetPriceUSD: priceResult.result as bigint | undefined,
          userSupplyAmount: depositResult.result as bigint | undefined,
          userBorrowAmount: borrowResult.result as bigint | undefined,
          currentAnnualLiquidityRateRAY:
            assetData?.currentAnnualLiquidityRateRAY,
          currentAnnualVariableBorrowRateRAY:
            assetData?.currentAnnualVariableBorrowRateRAY,
        });
      } else {
        console.warn(
          `Failed to fetch complete data for asset ${assetConfig.symbol}`
        );
      }
    }
    return details;
  }, [batchAssetsData, supportedAssetsList]);

  const suppliedAssets = useMemo(
    () =>
      userAssetsDetails.filter(
        (asset) => asset.userSupplyAmount && asset.userSupplyAmount > 0n
      ),
    [userAssetsDetails]
  );
  const borrowedAssets = useMemo(
    () =>
      userAssetsDetails.filter(
        (asset) => asset.userBorrowAmount && asset.userBorrowAmount > 0n
      ),
    [userAssetsDetails]
  );

  const healthFactorValue = useMemo(() => {
    if (typeof healthFactor === 'bigint') {
      return Number(healthFactor) / 1e18; // Health Factor is usually 1e18 scaled
    }
    return undefined;
  }, [healthFactor]);

  const healthFactorDisplay = useMemo(() => {
    if (healthFactorValue !== undefined) {
      // Aave considers HF === type(uint256).max as "no debt" or "infinite HF"
      if (healthFactor === 2n ** 256n - 1n) return '∞ (无借款)';
      return healthFactorValue.toFixed(USD_DISPLAY_DECIMALS); // 健康因子通常显示2位小数
    }
    return 'N/A';
  }, [healthFactorValue, healthFactor]);

  // 新增：计算健康因子状态和提示信息
  const healthStatus = useMemo((): HealthStatus => {
    if (healthFactorValue === undefined) {
      return {
        level: 'nodata',
        message: '健康因子数据加载中或不可用。',
        className: styles.healthFactorNoData,
      };
    }
    // Aave considers HF === type(uint256).max as "no debt" or "infinite HF", which is safe.
    if (
      healthFactor === 2n ** 256n - 1n ||
      (typeof totalDebtUSD === 'bigint' && totalDebtUSD === 0n)
    ) {
      return {
        level: 'nodebt',
        message: '您当前没有借款，账户非常安全。',
        className: styles.healthFactorGood,
      };
    }
    if (healthFactorValue <= DANGER_HF_THRESHOLD) {
      return {
        level: 'danger',
        message:
          '健康度非常低，有较高的清算风险！强烈建议立即增加抵押或偿还借款以避免清算。',
        className: styles.healthFactorDanger,
      };
    }
    if (healthFactorValue <= WARNING_HF_THRESHOLD) {
      return {
        level: 'warning',
        message: '健康度较低，请注意清算风险。可以尝试增加抵押或偿还部分借款。',
        className: styles.healthFactorWarning,
      };
    }
    return {
      level: 'safe',
      message: '您的账户目前处于安全状态。',
      className: styles.healthFactorGood,
    };
  }, [healthFactorValue, healthFactor, totalDebtUSD]);

  if (!isConnected) {
    return (
      <div className={styles.overviewContainer}>
        <p>请先连接钱包查看账户概览。</p>
      </div>
    );
  }

  const isLoading =
    isLoadingTotalCollateralUSD ||
    isLoadingTotalDebtUSD ||
    isLoadingAvailableBorrowsUSD ||
    isLoadingHealthFactor ||
    isLoadingSupportedAssets ||
    isLoadingBatchAssetsData;
  const mainError =
    errorTotalCollateralUSD ||
    errorTotalDebtUSD ||
    errorAvailableBorrowsUSD ||
    errorHealthFactor ||
    errorSupportedAssets ||
    errorBatchAssetsData;

  if (isLoading) {
    return (
      <div className={styles.overviewContainer}>
        <p>加载账户数据中...</p>
      </div>
    );
  }

  if (mainError) {
    return (
      <div className={styles.overviewContainer}>
        <p className={styles.errorMessage}>
          加载账户数据失败: {getErrorMessage(mainError)}
        </p>
      </div>
    );
  }

  return (
    <div className={styles.overviewContainer}>
      <h2>账户概览</h2>
      <div className={styles.globalStats}>
        <div className={styles.statItem}>
          <span>总抵押价值:</span>
          <strong>{`$${formatDisplayNumber(
            totalCollateralUSD,
            ORACLE_PRICE_DECIMALS,
            USD_DISPLAY_DECIMALS
          )}`}</strong>
        </div>
        <div className={styles.statItem}>
          <span>总借款价值:</span>
          <strong>{`$${formatDisplayNumber(
            totalDebtUSD,
            ORACLE_PRICE_DECIMALS,
            USD_DISPLAY_DECIMALS
          )}`}</strong>
        </div>
        <div className={styles.statItem}>
          <span>可借额度:</span>
          <strong>{`$${formatDisplayNumber(
            availableBorrowsUSD,
            ORACLE_PRICE_DECIMALS,
            USD_DISPLAY_DECIMALS
          )}`}</strong>
        </div>
        <div className={styles.statItem}>
          <span>健康因子:</span>
          <strong className={healthStatus.className}>
            {healthFactorDisplay}
          </strong>
        </div>
      </div>
      {(healthStatus.level === 'warning' ||
        healthStatus.level === 'danger') && (
        <p
          className={`${styles.healthFactorMessage} ${healthStatus.className}`}
        >
          {healthStatus.message}
        </p>
      )}
      {healthStatus.level === 'nodebt' &&
        typeof totalDebtUSD === 'bigint' &&
        totalDebtUSD === 0n && (
          <p
            className={`${styles.healthFactorMessage} ${styles.healthFactorGood}`}
          >
            {healthStatus.message}
          </p>
        )}

      <div className={styles.assetListsContainer}>
        <div className={styles.assetListSection}>
          <h3>已供应资产</h3>
          {suppliedAssets.length > 0 ? (
            <table className={styles.assetTable}>
              <thead>
                <tr>
                  <th>资产</th>
                  <th>余额</th>
                  <th>价值 (USD)</th>
                  <th>APY</th>
                </tr>
              </thead>
              <tbody>
                {suppliedAssets.map((asset) => {
                  const supplyValueUSD =
                    asset.userSupplyAmount &&
                    asset.assetPriceUSD &&
                    asset.decimals // 使用 asset.decimals
                      ? (asset.userSupplyAmount * asset.assetPriceUSD) /
                        10n ** BigInt(asset.decimals)
                      : 0n;
                  const depositAPY =
                    asset.currentAnnualLiquidityRateRAY &&
                    typeof asset.currentAnnualLiquidityRateRAY === 'bigint' &&
                    asset.currentAnnualLiquidityRateRAY >= 0n
                      ? `${(
                          Number(
                            (asset.currentAnnualLiquidityRateRAY *
                              BASIS_POINTS_BI) /
                              RAY_BI
                          ) / 100
                        ).toFixed(USD_DISPLAY_DECIMALS)}%`
                      : 'N/A';
                  return (
                    <tr key={asset.underlyingAddress}>
                      <td>{asset.symbol}</td>
                      <td>
                        {formatDisplayNumber(
                          asset.userSupplyAmount,
                          asset.decimals,
                          DEFAULT_TOKEN_DISPLAY_DECIMALS
                        )}
                      </td>
                      <td>
                        $
                        {formatDisplayNumber(
                          supplyValueUSD,
                          ORACLE_PRICE_DECIMALS,
                          USD_DISPLAY_DECIMALS
                        )}
                      </td>
                      <td className={styles.apyRate}>{depositAPY}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          ) : (
            <p>你还没有供应任何资产。</p>
          )}
        </div>

        <div className={styles.assetListSection}>
          <h3>已借款资产</h3>
          {borrowedAssets.length > 0 ? (
            <table className={styles.assetTable}>
              <thead>
                <tr>
                  <th>资产</th>
                  <th>借款额</th>
                  <th>价值 (USD)</th>
                  <th>APR</th>
                </tr>
              </thead>
              <tbody>
                {borrowedAssets.map((asset) => {
                  const borrowValueUSD =
                    asset.userBorrowAmount &&
                    asset.assetPriceUSD &&
                    asset.decimals // 使用 asset.decimals
                      ? (asset.userBorrowAmount * asset.assetPriceUSD) /
                        10n ** BigInt(asset.decimals)
                      : 0n;
                  const variableBorrowAPR =
                    asset.currentAnnualVariableBorrowRateRAY &&
                    typeof asset.currentAnnualVariableBorrowRateRAY ===
                      'bigint' &&
                    asset.currentAnnualVariableBorrowRateRAY >= 0n
                      ? `${(
                          Number(
                            (asset.currentAnnualVariableBorrowRateRAY *
                              BASIS_POINTS_BI) /
                              RAY_BI
                          ) / 100
                        ).toFixed(USD_DISPLAY_DECIMALS)}%`
                      : 'N/A';
                  return (
                    <tr key={asset.underlyingAddress}>
                      <td>{asset.symbol}</td>
                      <td>
                        {formatDisplayNumber(
                          asset.userBorrowAmount,
                          asset.decimals,
                          DEFAULT_TOKEN_DISPLAY_DECIMALS
                        )}
                      </td>
                      <td>
                        $
                        {formatDisplayNumber(
                          borrowValueUSD,
                          ORACLE_PRICE_DECIMALS,
                          USD_DISPLAY_DECIMALS
                        )}
                      </td>
                      <td className={styles.aprRate}>{variableBorrowAPR}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          ) : (
            <p>你还没有借入任何资产。</p>
          )}
        </div>
      </div>
    </div>
  );
}

export default UserAccountOverview;
