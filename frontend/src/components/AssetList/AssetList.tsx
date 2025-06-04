import React from 'react';
import { useAccount, useReadContract } from 'wagmi';
import { type Address, type Abi } from 'viem';

import {
  LendingPoolContractConfig,
  SUPPORTED_ASSETS_CONFIG,
  type AssetConfig,
} from '@/config/contracts';
import AssetCard from '@/components/AssetCard/AssetCard'; // 确保 AssetCard 路径正确
import styles from './AssetList.module.css'; // 引入 CSS Modules

function AssetList() {
  const { isConnected } = useAccount();

  const {
    data: supportedAssetsAddresses,
    isLoading: isLoadingSupportedAssets,
    error: errorSupportedAssets,
  } = useReadContract({
    ...LendingPoolContractConfig,
    abi: LendingPoolContractConfig.abi as Abi, // 添加 ABI 类型断言
    functionName: 'getSupportedAssets',
    query: {
      enabled: isConnected, // 仅当钱包连接时获取
    },
  }) as {
    data: Address[] | undefined;
    isLoading: boolean;
    error: Error | null;
  }; // 类型断言

  if (!isConnected) {
    // 如果未连接钱包，AssetList 本身可以不渲染，或者显示一个提示
    // MarketPage 中已经有连接提示，这里可以返回 null 或一个更简单的占位符
    return null;
  }

  if (isLoadingSupportedAssets) {
    return (
      <div className={styles.loadingContainer}>
        {/* <LoadingSpinner message="正在加载支持的资产列表..." size="large" /> */}
        <p>正在加载支持的资产列表...</p>
      </div>
    );
  }

  if (errorSupportedAssets) {
    return (
      <div className={styles.errorContainer}>
        <p>加载支持资产列表失败: {errorSupportedAssets.message}</p>
      </div>
    );
  }

  if (!supportedAssetsAddresses || supportedAssetsAddresses.length === 0) {
    return (
      <div className={styles.emptyContainer}>
        <p>当前没有支持的资产可供操作。</p>
      </div>
    );
  }

  return (
    <div className={styles.assetListContainer}>
      <h2>市场资产</h2>
      <div className={styles.cardsWrapper}>
        {supportedAssetsAddresses.map((assetAddr: Address) => {
          const assetConfig = SUPPORTED_ASSETS_CONFIG.find(
            (a: AssetConfig) =>
              a.underlyingAddress.toLowerCase() === assetAddr.toLowerCase()
          );
          if (!assetConfig) {
            return (
              <div key={assetAddr} className={styles.configErrorCard}>
                为地址 {assetAddr} 找不到资产配置。请检查
                `SUPPORTED_ASSETS_CONFIG`。
              </div>
            );
          }
          return (
            <AssetCard
              key={assetConfig.underlyingAddress}
              assetConfig={assetConfig}
            />
          );
        })}
      </div>
    </div>
  );
}

export default AssetList;
