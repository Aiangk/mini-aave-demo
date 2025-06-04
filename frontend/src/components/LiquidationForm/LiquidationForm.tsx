// src/components/LiquidationForm/LiquidationForm.tsx
import React, { useState, useEffect, useMemo } from 'react';
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
} from 'wagmi';
import { type Address, type Abi, parseUnits, formatUnits } from 'viem';
import { toast } from 'react-toastify';

import {
  LendingPoolContractConfig,
  SUPPORTED_ASSETS_CONFIG,
  type AssetConfig,
  type GetAssetDataReturnType,
} from '@/config/contracts'; // 确保 GetAssetDataReturnType 从这里导入
import { getErrorMessage } from '@/utils/errors';
import styles from './LiquidationForm.module.css';

const ORACLE_PRICE_DECIMALS = 8;
const DEFAULT_TOKEN_DISPLAY_DECIMALS = 4;
const USD_DISPLAY_DECIMALS = 2;
const RAY_BI = 10n ** 27n;
const MINIMUM_HEALTH_FACTOR_SOLIDITY = 10n ** 18n; // 对应 Solidity 中的 1e18

// 辅助函数：格式化显示的金额 (与 AssetCard.tsx 中的类似)
function formatDisplayNumber(
  value: bigint | undefined,
  baseDecimals: number,
  displayDecimals: number
): string {
  if (value === undefined || value === null) return 'N/A';
  const formatted = formatUnits(value, baseDecimals);
  const num = parseFloat(formatted);
  if (isNaN(num)) return 'N/A';
  // 对于非常小但非零的值，可以考虑更复杂的显示逻辑
  if (num > 0 && num < Math.pow(10, -displayDecimals)) {
    return `< ${Math.pow(10, -displayDecimals).toFixed(displayDecimals)}`;
  }
  return num.toFixed(displayDecimals);
}

function LiquidationForm() {
  const { address: connectedUserAddress, isConnected } = useAccount();

  const [userToLiquidate, setUserToLiquidate] = useState<Address | ''>('');
  const [debtAssetAddress, setDebtAssetAddress] = useState<Address | ''>('');
  const [collateralAssetAddress, setCollateralAssetAddress] = useState<
    Address | ''
  >('');
  const [debtAmountToCover, setDebtAmountToCover] = useState<string>('');

  const [isFetchingDetails, setIsFetchingDetails] = useState<boolean>(false);
  const [userHealthFactor, setUserHealthFactor] = useState<bigint | undefined>(
    undefined
  );
  const [userDebtForAsset, setUserDebtForAsset] = useState<bigint | undefined>(
    undefined
  );
  const [userCollateralForAsset, setUserCollateralForAsset] = useState<
    bigint | undefined
  >(undefined);
  const [debtAssetPrice, setDebtAssetPrice] = useState<bigint | undefined>(
    undefined
  );
  const [collateralAssetPrice, setCollateralAssetPrice] = useState<
    bigint | undefined
  >(undefined);

  const [collateralAssetFullData, setCollateralAssetFullData] =
    useState<GetAssetDataReturnType | null>(null);

  const [debtAssetConfig, setDebtAssetConfig] = useState<AssetConfig | null>(
    null
  );
  const [collateralAssetConfigState, setCollateralAssetConfigState] =
    useState<AssetConfig | null>(null);

  const [isApproving, setIsApproving] = useState<boolean>(false);
  const [isLiquidating, setIsLiquidating] = useState<boolean>(false);

  const debtAmountToCoverBigInt = useMemo(() => {
    if (
      !debtAmountToCover ||
      isNaN(parseFloat(debtAmountToCover)) ||
      parseFloat(debtAmountToCover) <= 0 ||
      !debtAssetConfig
    )
      return 0n;
    try {
      return parseUnits(debtAmountToCover, debtAssetConfig.decimals);
    } catch (e) {
      return 0n;
    }
  }, [debtAmountToCover, debtAssetConfig]);

  // --- Wagmi Hooks for Data Reading ---
  const { refetch: refetchUserHealthFactor } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'calculateHealthFactor',
    args: [userToLiquidate || '0x0000000000000000000000000000000000000000'],
    query: {
      enabled: false,
    },
  });

  const { refetch: refetchUserDebtForAsset } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getEffectiveUserBorrowBalance',
    args: [
      debtAssetAddress || '0x0000000000000000000000000000000000000000',
      userToLiquidate || '0x0000000000000000000000000000000000000000',
    ],
    query: {
      enabled: false,
    },
  });

  const { refetch: refetchUserCollateralForAsset } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getEffectiveUserDeposit',
    args: [
      collateralAssetAddress || '0x0000000000000000000000000000000000000000',
      userToLiquidate || '0x0000000000000000000000000000000000000000',
    ],
    query: {
      enabled: false,
    },
  });

  const { refetch: refetchDebtAssetPrice } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getAssetPrice',
    args: [debtAssetAddress || '0x0000000000000000000000000000000000000000'],
    query: {
      enabled: false,
    },
  });

  const { refetch: refetchCollateralAssetPrice } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getAssetPrice',
    args: [
      collateralAssetAddress || '0x0000000000000000000000000000000000000000',
    ],
    query: {
      enabled: false,
    },
  });

  const { refetch: refetchCollateralAssetFullData } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getAssetData',
    args: [
      collateralAssetAddress || '0x0000000000000000000000000000000000000000',
    ],
    query: {
      enabled: false,
    },
  });

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: debtAssetAddress || undefined,
    abi: debtAssetConfig?.erc20Abi as Abi | undefined,
    functionName: 'allowance',
    args: [connectedUserAddress as Address, LendingPoolContractConfig.address],
    query: {
      enabled:
        !!connectedUserAddress && !!debtAssetAddress && !!debtAssetConfig,
    },
  });

  const {
    writeContractAsync: approveAsync,
    data: approveTxHash,
    reset: resetApprove,
    error: approveSubmissionError,
  } = useWriteContract();
  const {
    isLoading: isConfirmingApproval,
    isSuccess: isApprovalSuccess,
    error: approveConfirmationError,
  } = useWaitForTransactionReceipt({ hash: approveTxHash });

  const {
    writeContractAsync: liquidationCallAsync,
    data: liquidationTxHash,
    reset: resetLiquidation,
    error: liquidationSubmissionError,
  } = useWriteContract();
  const {
    isLoading: isConfirmingLiquidation,
    isSuccess: isLiquidationSuccess,
    error: liquidationConfirmationError,
  } = useWaitForTransactionReceipt({ hash: liquidationTxHash });

  // --- 事件处理器 ---
  const handleFetchUserDetails = async () => {
    if (!userToLiquidate || !debtAssetAddress || !collateralAssetAddress) {
      toast.warn('请输入被清算人地址并选择所有相关资产。');
      return;
    }
    setIsFetchingDetails(true);
    setUserHealthFactor(undefined);
    setUserDebtForAsset(undefined);
    setUserCollateralForAsset(undefined);
    setDebtAssetPrice(undefined);
    setCollateralAssetPrice(undefined);
    setCollateralAssetFullData(null);

    const selectedDebtAssetConfig =
      SUPPORTED_ASSETS_CONFIG.find(
        (a) =>
          a.underlyingAddress.toLowerCase() === debtAssetAddress.toLowerCase()
      ) || null;
    const selectedCollateralAssetConfig =
      SUPPORTED_ASSETS_CONFIG.find(
        (a) =>
          a.underlyingAddress.toLowerCase() ===
          collateralAssetAddress.toLowerCase()
      ) || null;

    setDebtAssetConfig(selectedDebtAssetConfig);
    setCollateralAssetConfigState(selectedCollateralAssetConfig);

    if (!selectedDebtAssetConfig || !selectedCollateralAssetConfig) {
      toast.error('选择的资产配置无效。');
      setIsFetchingDetails(false);
      return;
    }

    try {
      console.log(
        `Fetching details for user: ${userToLiquidate}, debt: ${debtAssetAddress}, collateral: ${collateralAssetAddress}`
      );

      const promises = [
        refetchUserHealthFactor({ throwOnError: true }),
        refetchUserDebtForAsset({ throwOnError: true }),
        refetchUserCollateralForAsset({ throwOnError: true }),
        refetchDebtAssetPrice({ throwOnError: true }),
        refetchCollateralAssetPrice({ throwOnError: true }),
        refetchCollateralAssetFullData({ throwOnError: true }),
      ];

      const results = await Promise.all(promises);

      const hfResult = results[0] as {
        data: bigint | undefined;
        error?: Error | null;
      };
      const debtBalanceResult = results[1] as {
        data: bigint | undefined;
        error?: Error | null;
      };
      const collateralBalanceResult = results[2] as {
        data: bigint | undefined;
        error?: Error | null;
      };
      const debtPriceResult = results[3] as {
        data: bigint | undefined;
        error?: Error | null;
      };
      const collateralPriceResult = results[4] as {
        data: bigint | undefined;
        error?: Error | null;
      };
      const collateralFullDataResult = results[5] as {
        data: GetAssetDataReturnType | undefined;
        error?: Error | null;
      };

      console.log('Health Factor Result:', hfResult);
      console.log('Debt Balance Result:', debtBalanceResult);
      console.log('Collateral Balance Result:', collateralBalanceResult);
      console.log('Debt Price Result:', debtPriceResult);
      console.log('Collateral Price Result:', collateralPriceResult);
      console.log('Collateral Full Data Result:', collateralFullDataResult);

      if (
        hfResult?.error ||
        debtBalanceResult?.error ||
        collateralBalanceResult?.error ||
        debtPriceResult?.error ||
        collateralPriceResult?.error ||
        collateralFullDataResult?.error
      ) {
        let errorMessage = '获取部分用户详情失败。具体错误：';
        results.forEach((res, index) => {
          if (res?.error)
            errorMessage += `\n查询 ${index + 1}: ${getErrorMessage(
              res.error
            )}`;
        });
        toast.error(errorMessage, { autoClose: 10000 }); // 延长 toast 显示时间
        console.error(
          'One or more refetch calls failed:',
          results.map((r) => r?.error).filter(Boolean)
        );
      }

      setUserHealthFactor(hfResult?.data);
      setUserDebtForAsset(debtBalanceResult?.data);
      setUserCollateralForAsset(collateralBalanceResult?.data);
      setDebtAssetPrice(debtPriceResult?.data);
      setCollateralAssetPrice(collateralPriceResult?.data);
      setCollateralAssetFullData(collateralFullDataResult?.data || null);
    } catch (error: any) {
      console.error('获取用户详情失败 (Promise.all catch):', error);
      if (
        error.name === 'CancelledError' ||
        (error.message && error.message.includes('cancelled'))
      ) {
        toast.warn(
          '查询用户详情被取消。如果输入或选择了相同资产，请稍后再试或确保网络稳定。'
        );
      } else {
        toast.error(`获取用户详情失败: ${getErrorMessage(error)}`);
      }
    } finally {
      setIsFetchingDetails(false);
    }
  };

  const expectedCollateralToReceive = useMemo(() => {
    if (
      !debtAmountToCoverBigInt ||
      debtAmountToCoverBigInt <= 0n ||
      !debtAssetPrice ||
      debtAssetPrice === 0n ||
      !collateralAssetPrice ||
      collateralAssetPrice === 0n ||
      !debtAssetConfig ||
      !collateralAssetConfigState ||
      !collateralAssetFullData
    ) {
      return 0n;
    }

    const liquidationBonusBps = collateralAssetFullData.liquidationBonus;
    if (typeof liquidationBonusBps !== 'bigint') return 0n;

    const debtToCoverValueUSD =
      (debtAmountToCoverBigInt * debtAssetPrice) /
      10n ** BigInt(debtAssetConfig.decimals);
    const collateralToReceiveValueUSD =
      (debtToCoverValueUSD * (10000n + liquidationBonusBps)) / 10000n;
    const amountOfCollateral =
      (collateralToReceiveValueUSD *
        10n ** BigInt(collateralAssetConfigState.decimals)) /
      collateralAssetPrice;

    return amountOfCollateral;
  }, [
    debtAmountToCoverBigInt,
    debtAssetPrice,
    collateralAssetPrice,
    debtAssetConfig,
    collateralAssetConfigState,
    collateralAssetFullData,
  ]);

  const handleApproveDebtAsset = async () => {
    if (
      !debtAssetAddress ||
      !debtAssetConfig ||
      debtAmountToCoverBigInt <= 0n
    ) {
      toast.warn('请选择债务资产并输入有效金额。');
      return;
    }
    setIsApproving(true);
    try {
      await approveAsync({
        address: debtAssetAddress as Address,
        abi: debtAssetConfig.erc20Abi as Abi,
        functionName: 'approve',
        args: [LendingPoolContractConfig.address, debtAmountToCoverBigInt],
      });
    } catch (e) {
      toast.error(`授权债务资产失败: ${getErrorMessage(e)}`);
      setIsApproving(false);
      resetApprove();
    }
  };

  const handleLiquidationCall = async () => {
    if (
      !userToLiquidate ||
      !debtAssetAddress ||
      !collateralAssetAddress ||
      debtAmountToCoverBigInt <= 0n ||
      !collateralAssetConfigState
    ) {
      toast.warn('请填写所有必填项并确保金额有效。');
      return;
    }
    const currentHealthFactorNum = userHealthFactor
      ? Number(userHealthFactor) / 1e18
      : Infinity;
    if (userHealthFactor === undefined || currentHealthFactorNum >= MINIMUM_HEALTH_FACTOR_SOLIDITY) {
      toast.warn(
        `该用户健康因子 (${currentHealthFactorNum.toFixed(
          2
        )}) 不满足清算条件 (需 < 1)。`
      );
      return;
    }
    if (debtAmountToCoverBigInt > (userDebtForAsset || 0n)) {
      toast.warn('偿还金额超过用户实际债务。');
      return;
    }
    if (
      expectedCollateralToReceive <= 0n ||
      expectedCollateralToReceive > (userCollateralForAsset || 0n)
    ) {
      toast.warn(
        '用户抵押品不足或计算出的可获抵押品为0。请尝试调整偿还的债务金额。'
      );
      return;
    }

    const needsApproval =
      typeof allowance !== 'bigint' || allowance < debtAmountToCoverBigInt;
    if (needsApproval) {
      if (isApproving) return;
      await handleApproveDebtAsset();
      toast.info('请在授权成功后再次点击执行清算。');
      return;
    }

    setIsLiquidating(true);
    try {
      await liquidationCallAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'liquidationCall',
        args: [
          collateralAssetAddress as Address,
          debtAssetAddress as Address,
          userToLiquidate as Address,
          debtAmountToCoverBigInt,
          true,
        ],
      });
    } catch (e) {
      toast.error(`执行清算失败: ${getErrorMessage(e)}`);
      setIsLiquidating(false);
      resetLiquidation();
    }
  };

  useEffect(() => {
    if (!isConfirmingApproval && approveTxHash) {
      if (isApprovalSuccess) {
        toast.success(`债务资产授权成功!`);
        refetchAllowance();
      } else if (approveConfirmationError) {
        toast.error(`授权失败: ${getErrorMessage(approveConfirmationError)}`);
      } else if (approveSubmissionError) {
        toast.error(`授权提交失败: ${getErrorMessage(approveSubmissionError)}`);
      }
      setIsApproving(false);
      resetApprove();
    }
  }, [
    isApprovalSuccess,
    isConfirmingApproval,
    approveTxHash,
    approveConfirmationError,
    approveSubmissionError,
    resetApprove,
    refetchAllowance,
  ]);

  useEffect(() => {
    if (!isConfirmingLiquidation && liquidationTxHash) {
      if (isLiquidationSuccess) {
        toast.success(`清算成功!`);
        refetchUserHealthFactor?.({ throwOnError: false });
        refetchUserDebtForAsset?.({ throwOnError: false });
        refetchUserCollateralForAsset?.({ throwOnError: false });
        refetchCollateralAssetFullData?.({ throwOnError: false });
        refetchDebtAssetPrice?.({ throwOnError: false });
        refetchCollateralAssetPrice?.({ throwOnError: false });
        setDebtAmountToCover('');
      } else if (liquidationConfirmationError) {
        toast.error(
          `清算失败: ${getErrorMessage(liquidationConfirmationError)}`
        );
      } else if (liquidationSubmissionError) {
        toast.error(
          `清算提交失败: ${getErrorMessage(liquidationSubmissionError)}`
        );
      }
      setIsLiquidating(false);
      resetLiquidation();
    }
  }, [
    isLiquidationSuccess,
    isConfirmingLiquidation,
    liquidationTxHash,
    liquidationConfirmationError,
    liquidationSubmissionError,
    resetLiquidation,
    refetchUserHealthFactor,
    refetchUserDebtForAsset,
    refetchUserCollateralForAsset,
    refetchCollateralAssetFullData,
    refetchDebtAssetPrice,
    refetchCollateralAssetPrice,
  ]);

  const renderAssetOption = (asset: AssetConfig) => (
    <option key={asset.underlyingAddress} value={asset.underlyingAddress}>
      {asset.symbol}
    </option>
  );

  const healthFactorNumForDisplay = userHealthFactor
    ? Number(userHealthFactor) / 1e18
    : undefined;
  const canLiquidate =
    healthFactorNumForDisplay !== undefined && healthFactorNumForDisplay < 1;
  const showLiquidationActions =
    userHealthFactor !== undefined &&
    debtAssetConfig &&
    collateralAssetConfigState;

  return (
    <div className={styles.liquidationFormContainer}>
      <h3>执行清算</h3>
      <div className={styles.formGrid}>
        <div className={styles.formGroup}>
          <label htmlFor="userToLiquidate">被清算用户地址:</label>
          <input
            type="text"
            id="userToLiquidate"
            value={userToLiquidate}
            onChange={(e) => setUserToLiquidate(e.target.value as Address)}
            placeholder="输入用户地址 (0x...)"
          />
        </div>
        <div className={styles.formGroup}>
          <label htmlFor="debtAsset">选择偿还的债务资产:</label>
          <select
            id="debtAsset"
            value={debtAssetAddress}
            onChange={(e) => setDebtAssetAddress(e.target.value as Address)}
          >
            <option value="">-- 选择债务资产 --</option>
            {SUPPORTED_ASSETS_CONFIG.map(renderAssetOption)}
          </select>
        </div>
        <div className={styles.formGroup}>
          <label htmlFor="collateralAsset">选择接收的抵押资产:</label>
          <select
            id="collateralAsset"
            value={collateralAssetAddress}
            onChange={(e) =>
              setCollateralAssetAddress(e.target.value as Address)
            }
          >
            <option value="">-- 选择抵押资产 --</option>
            {SUPPORTED_ASSETS_CONFIG.map(renderAssetOption)}
          </select>
        </div>
      </div>

      <button
        onClick={handleFetchUserDetails}
        disabled={
          isFetchingDetails ||
          !userToLiquidate ||
          !debtAssetAddress ||
          !collateralAssetAddress
        }
        className={styles.fetchButton}
      >
        {isFetchingDetails ? '查询中...' : '查询用户借贷详情'}
      </button>

      {debtAssetConfig && userHealthFactor !== undefined && (
        <div className={styles.userDetails}>
          <h4>
            用户详情 (被清算人:{' '}
            {userToLiquidate ? `${userToLiquidate.substring(0, 6)}...` : 'N/A'})
          </h4>
          <p>
            健康因子:{' '}
            {healthFactorNumForDisplay !== undefined
              ? healthFactorNumForDisplay.toFixed(4)
              : 'N/A'}
            {canLiquidate && <span className={styles.warning}> (可清算!)</span>}
            {!canLiquidate && healthFactorNumForDisplay !== undefined && (
              <span className={styles.infoMessage}> (健康因子良好)</span>
            )}
          </p>
          <p>
            {debtAssetConfig.symbol} 债务余额:{' '}
            {userDebtForAsset !== undefined
              ? formatDisplayNumber(
                  userDebtForAsset,
                  debtAssetConfig.decimals,
                  DEFAULT_TOKEN_DISPLAY_DECIMALS
                )
              : 'N/A'}
          </p>
          {collateralAssetConfigState && (
            <p>
              {collateralAssetConfigState.symbol} 抵押余额:{' '}
              {userCollateralForAsset !== undefined
                ? formatDisplayNumber(
                    userCollateralForAsset,
                    collateralAssetConfigState.decimals,
                    DEFAULT_TOKEN_DISPLAY_DECIMALS
                  )
                : 'N/A'}
            </p>
          )}
          <p style={{ fontSize: '0.8em', color: '#888' }}>
            调试: {debtAssetConfig.symbol} 价格 (USD):{' '}
            {debtAssetPrice !== undefined
              ? formatDisplayNumber(
                  debtAssetPrice,
                  ORACLE_PRICE_DECIMALS,
                  USD_DISPLAY_DECIMALS
                )
              : 'N/A'}
          </p>
          {collateralAssetConfigState && (
            <p style={{ fontSize: '0.8em', color: '#888' }}>
              调试: {collateralAssetConfigState.symbol} 价格 (USD):{' '}
              {collateralAssetPrice !== undefined
                ? formatDisplayNumber(
                    collateralAssetPrice,
                    ORACLE_PRICE_DECIMALS,
                    USD_DISPLAY_DECIMALS
                  )
                : 'N/A'}
            </p>
          )}
        </div>
      )}

      {showLiquidationActions && (
        <div className={styles.liquidationAction}>
          <div className={styles.formGroup}>
            <label htmlFor="debtAmountToCover">
              偿还债务数量 ({debtAssetConfig?.symbol || '债务资产'}):
            </label>
            <input
              type="number"
              id="debtAmountToCover"
              value={debtAmountToCover}
              onChange={(e) => setDebtAmountToCover(e.target.value)}
              placeholder={`最大 ${
                userDebtForAsset !== undefined && debtAssetConfig
                  ? formatDisplayNumber(
                      userDebtForAsset,
                      debtAssetConfig.decimals,
                      DEFAULT_TOKEN_DISPLAY_DECIMALS
                    )
                  : ''
              }`}
            />
          </div>
          {expectedCollateralToReceive > 0n && collateralAssetConfigState && (
            <p className={styles.expectedReturn}>
              预计可获得抵押品:{' '}
              {formatDisplayNumber(
                expectedCollateralToReceive,
                collateralAssetConfigState.decimals,
                DEFAULT_TOKEN_DISPLAY_DECIMALS
              )}{' '}
              {collateralAssetConfigState.symbol}
            </p>
          )}

          {!canLiquidate && userHealthFactor !== undefined && (
            <p className={styles.infoMessage}>
              该用户健康因子 ({healthFactorNumForDisplay?.toFixed(4)})
              不满足清算条件 (需 &lt; 1)。
            </p>
          )}

          {(typeof allowance !== 'bigint' ||
            allowance < debtAmountToCoverBigInt) &&
          debtAmountToCoverBigInt > 0n ? (
            <button
              onClick={handleApproveDebtAsset}
              disabled={
                isApproving ||
                isConfirmingApproval ||
                isLiquidating ||
                !canLiquidate
              }
              className={`${styles.actionButton} ${styles.approveButton}`}
            >
              {isConfirmingApproval
                ? '授权确认中...'
                : isApproving
                ? '授权处理中...'
                : `授权 ${debtAssetConfig?.symbol || ''}`}
            </button>
          ) : (
            <button
              onClick={handleLiquidationCall}
              disabled={
                isLiquidating ||
                isConfirmingLiquidation ||
                debtAmountToCoverBigInt <= 0n ||
                isApproving ||
                expectedCollateralToReceive <= 0n ||
                !canLiquidate
              }
              className={styles.actionButton}
            >
              {isConfirmingLiquidation
                ? '清算确认中...'
                : isLiquidating
                ? '执行清算中...'
                : '执行清算'}
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export default LiquidationForm;
