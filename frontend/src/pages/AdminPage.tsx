import React, { useState, useEffect } from 'react';
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { type Address, type Abi } from 'viem';
import { toast } from 'react-toastify';

import { ConfiguratorContractConfig} from '@/config/contracts'; // 假设 Configurator 配置已添加
import { getErrorMessage } from '@/utils/errors';
import styles from './AdminPage.module.css'; // 我们将创建这个 CSS 文件

// 假设 Configurator 的 addAsset 函数参数
interface AddAssetParams {
  assetAddress: Address;
  ltv: bigint; // e.g., 7500 for 75%
  liquidationThreshold: bigint; // e.g., 8000 for 80%
  interestRateStrategyAddress: Address;
  reserveFactor: bigint; // e.g., 1000 for 10%
  liquidationBonus: bigint; // e.g., 500 for 5%
}

function AdminPage() {
  const { address: connectedUserAddress, isConnected } = useAccount();
  const [isOwner, setIsOwner] = useState<boolean>(false);
  const [isLoadingOwnerCheck, setIsLoadingOwnerCheck] = useState<boolean>(true);

  // 表单状态 for addAsset
  const [newAssetAddress, setNewAssetAddress] = useState<Address | ''>('');
  const [ltv, setLtv] = useState<string>(''); // LTV (e.g., 7500 for 75%)
  const [liquidationThreshold, setLiquidationThreshold] = useState<string>('');
  const [interestRateStrategy, setInterestRateStrategy] = useState<Address | ''>('');
  const [reserveFactor, setReserveFactor] = useState<string>(''); // Reserve factor (e.g., 1000 for 10%)
  const [liquidationBonus, setLiquidationBonus] = useState<string>('');
// 1. 检查当前用户是否是 Configurator 的 owner
const { data: configuratorOwner } = useReadContract({
    ...ConfiguratorContractConfig,
    functionName: 'owner',
    query: { enabled: isConnected },
  }) as { data: Address | undefined };

  useEffect(() => {
    if (isConnected && configuratorOwner && connectedUserAddress) {
      setIsOwner(configuratorOwner.toLowerCase() === connectedUserAddress.toLowerCase());
    } else {
      setIsOwner(false);
    }
    setIsLoadingOwnerCheck(false);
  }, [isConnected, configuratorOwner, connectedUserAddress]);

  // Wagmi hooks for Configurator.addAsset
  const { 
    writeContractAsync: addAssetAsync, 
    data: addAssetTxHash, 
    error: addAssetSubmissionError,
    reset: resetAddAsset 
  } = useWriteContract();
  const { 
    isLoading: isConfirmingAddAsset, 
    isSuccess: isAddAssetSuccess, 
    error: addAssetConfirmationError 
  } = useWaitForTransactionReceipt({ hash: addAssetTxHash });


  const handleAddAsset = async (e: React.FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    if (!isOwner) {
      toast.error("只有合约所有者才能执行此操作。");
      return;
    }
    if (!newAssetAddress || !ltv || !liquidationThreshold || !interestRateStrategy || !reserveFactor || !liquidationBonus) {
        toast.warn("请填写所有必填字段。");
        return;
    }

    try {
      const params: AddAssetParams = {
        assetAddress: newAssetAddress as Address,
        ltv: BigInt(ltv), // 例如 7500 (表示75.00%)
        liquidationThreshold: BigInt(liquidationThreshold), // 例如 8000 (表示80.00%)
        interestRateStrategyAddress: interestRateStrategy as Address,
        reserveFactor: BigInt(reserveFactor), // 例如 1000 (表示10.00%)
        liquidationBonus: BigInt(liquidationBonus), // 例如 500 (表示5.00%)
      };

      // TODO: 确保你的 Configurator.addAsset 函数的参数顺序和类型与这里匹配
      // 你可能还需要一个获取 MockERC20 decimals 的步骤，如果 configureAsset 需要它
      // 但通常 Configurator.addAsset 会调用 LendingPool.configureAsset，后者会从代币合约读取 decimals
      
      // 假设 Configurator.addAsset 的参数是 (address asset, uint256 ltv, uint256 liquidationThreshold, address rateStrategy, uint256 reserveFactor, uint256 liquidationBonus)
      await addAssetAsync({
        address: ConfiguratorContractConfig.address,
        abi: ConfiguratorContractConfig.abi as Abi,
        functionName: 'addAsset',
        args: [
          params.assetAddress,
          params.ltv,
          params.liquidationThreshold,
          params.interestRateStrategyAddress,
          params.reserveFactor,
          params.liquidationBonus
        ],
      });
    } catch (error) {
      toast.error(`添加资产失败: ${getErrorMessage(error)}`);
      resetAddAsset();
    }
  };
  
  useEffect(() => {
    if (!isConfirmingAddAsset && addAssetTxHash) {
        if (isAddAssetSuccess) {
            toast.success(`资产 ${newAssetAddress.substring(0,6)}... 添加配置成功! Tx: ${addAssetTxHash.substring(0,6)}...`);
            // 清空表单或刷新相关列表
            setNewAssetAddress(''); setLtv(''); setLiquidationThreshold(''); 
            setInterestRateStrategy(''); setReserveFactor(''); setLiquidationBonus('');
            // 可能需要一个方法来刷新 LendingPool 支持的资产列表
        } else if (addAssetConfirmationError) {
            toast.error(`添加资产交易失败: ${getErrorMessage(addAssetConfirmationError)}`);
        } else if (addAssetSubmissionError) {
            toast.error(`添加资产提交失败: ${getErrorMessage(addAssetSubmissionError)}`);
        }
        resetAddAsset();
    }
  }, [isAddAssetSuccess, isConfirmingAddAsset, addAssetTxHash, addAssetConfirmationError, addAssetSubmissionError, resetAddAsset, newAssetAddress]);


  if (isLoadingOwnerCheck) {
    return <div className={styles.pageContainer}><p>正在检查权限...</p></div>;
  }

  if (!isConnected) {
    return <div className={styles.pageContainer}><p>请先连接钱包以访问管理员页面。</p></div>;
  }

  if (!isOwner) {
    return (
      <div className={styles.pageContainer}>
        <header className={styles.pageHeader}><h1>管理员面板</h1></header>
        <p className={styles.permissionDenied}>抱歉，只有合约所有者才能访问此页面。</p>
      </div>
    );
  }

  const isLoadingAction = isConfirmingAddAsset || (addAssetTxHash && !isAddAssetSuccess && !addAssetConfirmationError && !addAssetSubmissionError);


  return (
    <div className={styles.pageContainer}>
      <header className={styles.pageHeader}>
        <h1>管理员面板</h1>
        <p>管理 Lending Pool 的资产配置。</p>
      </header>
      <main className={styles.mainContent}>
        <section className={styles.adminSection}>
          <h2>添加新资产到 Lending Pool</h2>
          <form onSubmit={handleAddAsset} className={styles.adminForm}>
            <div className={styles.formGroup}>
              <label htmlFor="newAssetAddress">资产合约地址:</label>
              <input type="text" id="newAssetAddress" value={newAssetAddress} onChange={(e) => setNewAssetAddress(e.target.value as Address)} placeholder="0x..." required />
            </div>
            <div className={styles.formGroup}>
              <label htmlFor="ltv">LTV (例如 7500 代表 75%):</label>
              <input type="number" id="ltv" value={ltv} onChange={(e) => setLtv(e.target.value)} placeholder="例如 7500" required />
            </div>
            <div className={styles.formGroup}>
              <label htmlFor="liquidationThreshold">清算门槛 (例如 8000 代表 80%):</label>
              <input type="number" id="liquidationThreshold" value={liquidationThreshold} onChange={(e) => setLiquidationThreshold(e.target.value)} placeholder="例如 8000" required />
            </div>
            <div className={styles.formGroup}>
              <label htmlFor="interestRateStrategy">利率策略合约地址:</label>
              <input type="text" id="interestRateStrategy" value={interestRateStrategy} onChange={(e) => setInterestRateStrategy(e.target.value as Address)} placeholder="0x..." required />
            </div>
             <div className={styles.formGroup}>
              <label htmlFor="reserveFactor">储备因子 (例如 1000 代表 10%):</label>
              <input type="number" id="reserveFactor" value={reserveFactor} onChange={(e) => setReserveFactor(e.target.value)} placeholder="例如 1000" required />
            </div>
            <div className={styles.formGroup}>
              <label htmlFor="liquidationBonus">清算奖励 (例如 500 代表 5%):</label>
              <input type="number" id="liquidationBonus" value={liquidationBonus} onChange={(e) => setLiquidationBonus(e.target.value)} placeholder="例如 500" required />
            </div>
            <button type="submit" className={styles.submitButton} disabled={isLoadingAction}>
              {isLoadingAction ? '处理中...' : '添加/更新资产配置'}
            </button>
          </form>
        </section>
        {/* 在这里可以添加更多管理员功能，例如更新现有资产配置、设置价格预言机等 */}
      </main>
    </div>
  );
}

export default AdminPage;