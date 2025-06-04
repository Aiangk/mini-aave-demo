// src/components/FlashLoanForm/FlashLoanForm.tsx
import React, { useState, useMemo, useEffect } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt, usePublicClient, useBalance } from 'wagmi'; // 添加 useBalance
import { type Address, type Abi, parseUnits, formatUnits, stringToHex, zeroAddress } from 'viem';
import { toast } from 'react-toastify';

import { LendingPoolContractConfig, SUPPORTED_ASSETS_CONFIG, type AssetConfig } from '@/config/contracts';
import { getErrorMessage } from '@/utils/errors';
import styles from './FlashLoanForm.module.css';
import { formatDisplayNumber, DEFAULT_TOKEN_DISPLAY_DECIMALS } from '@/utils/formatters'; // 假设已移至共享文件

const FLASHLOAN_FEE_BPS = 9n; 
const PERCENTAGE_FACTOR_BPS = 10000n;

// TODO: 确保这个地址是你实际部署的 FlashLoanReceiverExample 合约地址
const PRESET_RECEIVER_ADDRESS = '0x610178dA211FEF7D417bC0e6FeD39F05609AD788' as Address; // 从你之前的部署日志获取


function FlashLoanForm() {
  const { address: connectedUserAddress, isConnected } = useAccount();
  const publicClient = usePublicClient();

  const [assetAddress, setAssetAddress] = useState<Address | ''>('');
  const [amount, setAmount] = useState<string>('');
  const [selectedAssetConfig, setSelectedAssetConfig] = useState<AssetConfig | null>(null);

  const [isExecutingFlashLoan, setIsExecutingFlashLoan] = useState<boolean>(false);

  // 获取闪电贷接收者合约的余额
  const { data: receiverAssetBalance, refetch: refetchReceiverAssetBalance } = useBalance({
    address: PRESET_RECEIVER_ADDRESS,
    token: selectedAssetConfig?.underlyingAddress, // 动态获取选定资产的地址
    query: {
      enabled: !!isConnected && !!selectedAssetConfig && PRESET_RECEIVER_ADDRESS !== zeroAddress 
    },
  });

  const actualReceiverAddress = PRESET_RECEIVER_ADDRESS; 

  const amountBigInt = useMemo(() => {
    if (!amount || isNaN(parseFloat(amount)) || parseFloat(amount) <= 0 || !selectedAssetConfig) return 0n;
    try {
      return parseUnits(amount, selectedAssetConfig.decimals);
    } catch (e) { return 0n; }
  }, [amount, selectedAssetConfig]);

  const flashLoanFee = useMemo(() => {
    if (amountBigInt > 0n) {
      return (amountBigInt * FLASHLOAN_FEE_BPS) / PERCENTAGE_FACTOR_BPS;
    }
    return 0n;
  }, [amountBigInt]);

  const totalToRepay = useMemo(() => {
    return amountBigInt + flashLoanFee;
  }, [amountBigInt, flashLoanFee]);

  const { writeContractAsync: flashLoanAsync, data: flashLoanTxHash, reset: resetFlashLoan, error: flashLoanSubmissionError } = useWriteContract();
  const { isLoading: isConfirmingFlashLoan, isSuccess: isFlashLoanSuccess, error: flashLoanConfirmationError } = useWaitForTransactionReceipt({ hash: flashLoanTxHash });

  useEffect(() => {
    if (assetAddress) {
      const config = SUPPORTED_ASSETS_CONFIG.find(a => a.underlyingAddress.toLowerCase() === assetAddress.toLowerCase()) || null;
      setSelectedAssetConfig(config);
      if (config && actualReceiverAddress !== zeroAddress ) {
        refetchReceiverAssetBalance(); // 当选择的资产改变时，重新获取接收者余额
      }
    } else {
      setSelectedAssetConfig(null);
    }
  }, [assetAddress, actualReceiverAddress, refetchReceiverAssetBalance]);

  const handleExecuteFlashLoan = async () => {
    if (!isConnected || !connectedUserAddress) {
      toast.warn('请先连接钱包。');
      return;
    }
    if (!selectedAssetConfig || amountBigInt <= 0n) {
      toast.warn('请选择资产并输入有效的闪电贷金额。');
      return;
    }
    if (actualReceiverAddress === zeroAddress ) {
        toast.error('错误：闪电贷接收者合约地址未正确配置。请检查代码中的 PRESET_RECEIVER_ADDRESS。');
        return;
    }
    // 确保接收者合约有足够的余额支付手续费 (如果手续费由接收者支付且接收者初始余额不足以覆盖手续费)
    // 在我们的简单示例中，LendingPool 转给接收者 _amount, 接收者需要有 _fee 的额外资金
    // 或者，如果接收者只归还 _amount，则 LendingPool 需要从 initiator 收取 _fee
    // 当前合约设计是接收者归还 _amount + _fee
    if (receiverAssetBalance && receiverAssetBalance.value < flashLoanFee && selectedAssetConfig?.symbol !== receiverAssetBalance?.symbol ) {
        // 这个检查比较复杂，因为 receiverAssetBalance.value 是接收者合约中该资产的总余额
        // 而 flashLoanFee 是本次闪电贷的手续费。
        // 更准确的检查是，接收者合约在收到 _amount 后，其总余额是否 >= _amount + _fee
        // 简化：如果接收者现有余额小于手续费，可能不足以完成操作（除非它通过闪电贷本身获利来支付手续费）
        console.warn("接收者合约的此资产余额可能不足以支付闪电贷手续费。");
        toast.warn(`接收者合约的 ${selectedAssetConfig.symbol} 余额可能不足以支付手续费。`);
    }


    setIsExecutingFlashLoan(true);
    try {
      const params = stringToHex('', { size: 32 }); 

      await flashLoanAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'flashLoan',
        args: [
          actualReceiverAddress, 
          selectedAssetConfig.underlyingAddress,
          amountBigInt,
          params,
        ],
      });
    } catch (e) {
      toast.error(`发起闪电贷失败: ${getErrorMessage(e)}`);
      setIsExecutingFlashLoan(false);
      resetFlashLoan();
    }
  };

  useEffect(() => {
    if (!isConfirmingFlashLoan && flashLoanTxHash) {
      if (isFlashLoanSuccess) {
        toast.success(`闪电贷执行成功！Tx: ${flashLoanTxHash.substring(0, 6)}...`);
        setAmount(''); 
        refetchReceiverAssetBalance(); // 闪电贷成功后刷新接收者余额
      } else if (flashLoanConfirmationError) {
        toast.error(`闪电贷交易失败: ${getErrorMessage(flashLoanConfirmationError)}`);
      } else if (flashLoanSubmissionError) {
        toast.error(`闪电贷提交失败: ${getErrorMessage(flashLoanSubmissionError)}`);
      } else if (!isFlashLoanSuccess && !flashLoanConfirmationError && !flashLoanSubmissionError) {
        toast.warn(`闪电贷交易状态未知 (Tx: ${flashLoanTxHash.substring(0,6)}...)`);
      }
      setIsExecutingFlashLoan(false);
      resetFlashLoan();
    }
  }, [isFlashLoanSuccess, isConfirmingFlashLoan, flashLoanTxHash, flashLoanConfirmationError, flashLoanSubmissionError, resetFlashLoan, refetchReceiverAssetBalance]);


  const renderAssetOption = (asset: AssetConfig) => (
    asset.isDemo ? 
    <option key={asset.underlyingAddress} value={asset.underlyingAddress}>
      {asset.symbol}
    </option> 
    : null
  );
  
  const isLoading = isExecutingFlashLoan || isConfirmingFlashLoan;
  const receiverAddressDisplay = actualReceiverAddress === zeroAddress  
                                  ? '(请在代码中配置实际地址)' 
                                  : actualReceiverAddress;

  return (
    <div className={styles.flashLoanFormContainer}>
      <h4>发起闪电贷 (示例：借出并立即归还)</h4>
      <div className={styles.formGroup}>
        <label htmlFor="flashLoanAsset">选择闪电贷资产:</label>
        <select id="flashLoanAsset" value={assetAddress} onChange={(e) => setAssetAddress(e.target.value as Address)} disabled={isLoading}>
          <option value="">-- 选择资产 --</option>
          {SUPPORTED_ASSETS_CONFIG.map(renderAssetOption)}
        </select>
      </div>

      <div className={styles.formGroup}>
        <label htmlFor="flashLoanAmount">闪电贷金额 ({selectedAssetConfig?.symbol || ''}):</label>
        <input
          type="number"
          id="flashLoanAmount"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          placeholder="输入金额"
          disabled={isLoading || !selectedAssetConfig}
        />
      </div>

      {selectedAssetConfig && amountBigInt > 0n && (
        <div className={styles.summary}>
          <p>手续费 ({formatDisplayNumber(FLASHLOAN_FEE_BPS * 100n / PERCENTAGE_FACTOR_BPS, 0, 2)}%):
             {formatDisplayNumber(flashLoanFee, selectedAssetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} {selectedAssetConfig.symbol}
          </p>
          <p>需归还总额: 
            {formatDisplayNumber(totalToRepay, selectedAssetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} {selectedAssetConfig.symbol}
          </p>
        </div>
      )}

      {/* 新增：显示接收者合约的余额 */}
      {selectedAssetConfig && actualReceiverAddress !== zeroAddress  && (
        <div className={styles.receiverBalanceInfo}>
          <p>
            接收者合约 ({receiverAddressDisplay.substring(0,6)}...) 
            当前 {selectedAssetConfig.symbol} 余额: 
            <span>
              {receiverAssetBalance ? 
                formatDisplayNumber(receiverAssetBalance.value, selectedAssetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS) : 
                '加载中...'}
            </span>
          </p>
        </div>
      )}

      <button 
        onClick={handleExecuteFlashLoan} 
        disabled={isLoading || !selectedAssetConfig || amountBigInt <= 0n || !isConnected || actualReceiverAddress === zeroAddress} 
        className={styles.actionButton}
      >
        {isConfirmingFlashLoan ? '交易确认中...' : isExecutingFlashLoan ? '执行中...' : '执行闪电贷'}
      </button>
      <p className={styles.receiverInfo}>
        本次闪电贷将由预设的接收者合约处理：<br/>
        <code>{receiverAddressDisplay}</code>
      </p>
    </div>
  );
}

export default FlashLoanForm;
