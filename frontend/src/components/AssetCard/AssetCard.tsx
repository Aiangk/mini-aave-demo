import React, { useState, useEffect, useMemo } from 'react';
import {
  useAccount,
  useReadContract,
  useWriteContract,
  useWaitForTransactionReceipt,
  useBalance,
} from 'wagmi';
import { parseUnits, formatUnits, type Abi, type Address } from 'viem';
import { toast } from 'react-toastify';

import { getErrorMessage } from '@/utils/errors';
import styles from './AssetCard.module.css'; // 确保引入 CSS Modules
import {
  LendingPoolContractConfig,
  type AssetConfig,
} from '@/config/contracts';
import { type GetAssetDataReturnType } from '@/config/contracts/index';
import { formatDisplayNumber, DEFAULT_TOKEN_DISPLAY_DECIMALS, USD_DISPLAY_DECIMALS, PERCENTAGE_DISPLAY_DECIMALS } from '@/utils/formatters'; // 假设已移至共享文件

interface AssetCardProps {
  assetConfig: AssetConfig;
}

const MIN_HEALTH_FACTOR_FOR_BORROW = 1.1e18;
const ORACLE_PRICE_DECIMALS = 8;
const PERCENTAGE_FACTOR_BPS_DIVISOR = 100n; // 用于将 7500 (75%) 转换为 75.00


function AssetCard({ assetConfig }: AssetCardProps) {
  const { address: userAddress, isConnected } = useAccount();

  const [activeAction, setActiveAction] = useState<
    'deposit' | 'withdraw' | 'borrow' | 'repay' | null
  >('deposit');
  const [isApproving, setIsApproving] = useState<boolean>(false);

  const [depositAmount, setDepositAmount] = useState<string>('');
  const [isDepositing, setIsDepositing] = useState<boolean>(false);
  const [depositInputError, setDepositInputError] = useState<string>('');

  const depositAmountBigInt = useMemo(() => {
    if (
      !depositAmount ||
      isNaN(parseFloat(depositAmount)) ||
      parseFloat(depositAmount) <= 0
    )
      return 0n;
    try {
      return parseUnits(depositAmount, assetConfig.decimals);
    } catch (e) {
      return 0n;
    }
  }, [depositAmount, assetConfig.decimals]);

  const [withdrawAmount, setWithdrawAmount] = useState<string>('');
  const [isWithdrawing, setIsWithdrawing] = useState<boolean>(false);
  const [withdrawInputError, setWithdrawInputError] = useState<string>('');

  const withdrawAmountBigInt = useMemo(() => {
    if (
      !withdrawAmount ||
      isNaN(parseFloat(withdrawAmount)) ||
      parseFloat(withdrawAmount) <= 0
    )
      return 0n;
    try {
      return parseUnits(withdrawAmount, assetConfig.decimals);
    } catch (e) {
      return 0n;
    }
  }, [withdrawAmount, assetConfig.decimals]);

  const [borrowAmount, setBorrowAmount] = useState<string>('');
  const [isBorrowing, setIsBorrowing] = useState<boolean>(false);
  const [borrowInputError, setBorrowInputError] = useState<string>('');

  const borrowAmountBigInt = useMemo(() => {
    if (
      !borrowAmount ||
      isNaN(parseFloat(borrowAmount)) ||
      parseFloat(borrowAmount) <= 0
    )
      return 0n;
    try {
      return parseUnits(borrowAmount, assetConfig.decimals);
    } catch (e) {
      return 0n;
    }
  }, [borrowAmount, assetConfig.decimals]);

  const [repayAmount, setRepayAmount] = useState<string>('');
  const [isRepaying, setIsRepaying] = useState<boolean>(false);
  const [repayInputError, setRepayInputError] = useState<string>('');

  const repayAmountBigInt = useMemo(() => {
    if (
      !repayAmount ||
      isNaN(parseFloat(repayAmount)) ||
      parseFloat(repayAmount) <= 0
    )
      return 0n;
    try {
      return parseUnits(repayAmount, assetConfig.decimals);
    } catch (e) {
      return 0n;
    }
  }, [repayAmount, assetConfig.decimals]);

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: assetConfig.underlyingAddress,
    abi: assetConfig.erc20Abi as Abi,
    functionName: 'allowance',
    args: [userAddress as Address, LendingPoolContractConfig.address],
    query: {
      enabled:
        !!userAddress &&
        !!assetConfig.underlyingAddress &&
        (activeAction === 'deposit' || activeAction === 'repay'),
    },
  });

  const { data: userTokenBalance, refetch: refetchUserTokenBalance } =
    useBalance({
      address: userAddress,
      token: assetConfig.underlyingAddress,
      query: { enabled: !!userAddress && !!assetConfig.underlyingAddress },
    });

  const {
    data: assetChainDataObject,
    refetch: refetchAssetChainData,
    isLoading: isLoadingAssetData,
    error: errorAssetData,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getAssetData',
    args: [assetConfig.underlyingAddress],
    query: { enabled: !!assetConfig.underlyingAddress },
  });
  const typedAssetData = assetChainDataObject as
    | GetAssetDataReturnType
    | undefined;

  const { data: assetPriceUSD, isLoading: isLoadingAssetPrice } =
    useReadContract({
      address: LendingPoolContractConfig.address,
      abi: LendingPoolContractConfig.abi as Abi,
      functionName: 'getAssetPrice',
      args: [assetConfig.underlyingAddress],
      query: {
        enabled:
          !!assetConfig.underlyingAddress &&
          (activeAction === 'borrow' || activeAction === 'repay'),
      },
    }) as { data: bigint | undefined; isLoading: boolean; error: Error | null };

  const {
    data: userEffectiveDepositInPool,
    refetch: refetchUserEffectiveDepositInPool,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getEffectiveUserDeposit',
    args: [assetConfig.underlyingAddress, userAddress as Address],
    query: {
      enabled: !!userAddress && !!assetConfig.underlyingAddress && isConnected,
    },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: userAssetBorrowBalance,
    refetch: refetchUserAssetBorrowBalance,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getEffectiveUserBorrowBalance',
    args: [assetConfig.underlyingAddress, userAddress as Address],
    query: {
      enabled: !!userAddress && !!assetConfig.underlyingAddress && isConnected,
    },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: totalCollateralUSD,
    refetch: refetchTotalCollateralUSD,
    isLoading: isLoadingTotalCollateralUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserTotalCollateralUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: totalDebtUSD,
    refetch: refetchTotalDebtUSD,
    isLoading: isLoadingTotalDebtUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserTotalDebtUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: availableBorrowsUSD,
    refetch: refetchAvailableBorrowsUSD,
    isLoading: isLoadingAvailableBorrowsUSD,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'getUserAvailableBorrowsUSD',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: healthFactor,
    refetch: refetchHealthFactor,
    isLoading: isLoadingHealthFactor,
  } = useReadContract({
    address: LendingPoolContractConfig.address,
    abi: LendingPoolContractConfig.abi as Abi,
    functionName: 'calculateHealthFactor',
    args: [userAddress as Address],
    query: { enabled: !!userAddress && isConnected },
  }) as {
    data: bigint | undefined;
    refetch: () => void;
    isLoading: boolean;
    error: Error | null;
  };

  const {
    data: approveTxHash,
    writeContractAsync: approveAsync,
    error: approveSubmissionError,
    reset: resetApprove,
  } = useWriteContract();
  const {
    isLoading: isConfirmingApproval,
    isSuccess: isApprovalSuccess,
    error: approveConfirmationError,
  } = useWaitForTransactionReceipt({ hash: approveTxHash });

  const {
    data: depositTxHash,
    writeContractAsync: depositAsync,
    error: depositSubmissionError,
    reset: resetDeposit,
  } = useWriteContract();
  const {
    isLoading: isConfirmingDeposit,
    isSuccess: isDepositSuccess,
    error: depositConfirmationError,
  } = useWaitForTransactionReceipt({ hash: depositTxHash });

  const {
    data: withdrawTxHash,
    writeContractAsync: withdrawAsync,
    error: withdrawSubmissionError,
    reset: resetWithdraw,
  } = useWriteContract();
  const {
    isLoading: isConfirmingWithdraw,
    isSuccess: isWithdrawSuccess,
    error: withdrawConfirmationError,
  } = useWaitForTransactionReceipt({ hash: withdrawTxHash });

  const {
    data: borrowTxHash,
    writeContractAsync: borrowAsync,
    error: borrowSubmissionError,
    reset: resetBorrow,
  } = useWriteContract();
  const {
    isLoading: isConfirmingBorrow,
    isSuccess: isBorrowSuccess,
    error: borrowConfirmationError,
  } = useWaitForTransactionReceipt({ hash: borrowTxHash });

  const {
    data: repayTxHash,
    writeContractAsync: repayAsync,
    error: repaySubmissionError,
    reset: resetRepay,
  } = useWriteContract();
  const {
    isLoading: isConfirmingRepay,
    isSuccess: isRepaySuccess,
    error: repayConfirmationError,
  } = useWaitForTransactionReceipt({ hash: repayTxHash });

  const currentAnnualLiquidityRateRAY =
    typedAssetData?.currentAnnualLiquidityRateRAY;
  const currentAnnualVariableBorrowRateRAY =
    typedAssetData?.currentAnnualVariableBorrowRateRAY;
  const liquidityIndex = typedAssetData?.liquidityIndex;
  const variableBorrowIndex = typedAssetData?.variableBorrowIndex;
  const totalScaledDeposits = typedAssetData?.totalScaledDeposits;
  const totalScaledVariableBorrows = typedAssetData?.totalScaledVariableBorrows;
  const ltv = typedAssetData?.ltv;
  const liquidationThreshold = typedAssetData?.liquidationThreshold;
  const reserveFactor = typedAssetData?.reserveFactor;
  const liquidationBonus = typedAssetData?.liquidationBonus;

  const RAY_BI = 10n ** 27n;
  const BASIS_POINTS_BI = 10000n;

  const depositAPYDisplay = useMemo(() => {
    if (typeof currentAnnualLiquidityRateRAY === 'bigint' && currentAnnualLiquidityRateRAY >= 0n) {
      const apyInBasisPoints = (currentAnnualLiquidityRateRAY * BASIS_POINTS_BI) / RAY_BI;
      return `${(Number(apyInBasisPoints) / 100).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%`;
    }
    return 'N/A';
  }, [currentAnnualLiquidityRateRAY]);

  const variableBorrowAPRDisplay = useMemo(() => {
    if (typeof currentAnnualVariableBorrowRateRAY === 'bigint' && currentAnnualVariableBorrowRateRAY >= 0n) {
      const aprInBasisPoints = (currentAnnualVariableBorrowRateRAY * BASIS_POINTS_BI) / RAY_BI;
      return `${(Number(aprInBasisPoints) / 100).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%`;
    }
    return 'N/A';
  }, [currentAnnualVariableBorrowRateRAY]);

  const healthFactorDisplay = useMemo(() => {
    if (typeof healthFactor === 'bigint') {
      if (healthFactor === (2n**256n - 1n)) return "∞";
      return (Number(healthFactor) / 1e18).toFixed(USD_DISPLAY_DECIMALS);
    }
    return 'N/A';
  }, [healthFactor]);
  
  const totalActualDeposits = useMemo(() => {
    if (typeof totalScaledDeposits === 'bigint' && typeof liquidityIndex === 'bigint') {
        return (totalScaledDeposits * liquidityIndex) / RAY_BI;
    }
    return 0n;
  }, [totalScaledDeposits, liquidityIndex]);

  const totalActualBorrows = useMemo(() => {
    if (typeof totalScaledVariableBorrows === 'bigint' && typeof variableBorrowIndex === 'bigint') {
        return (totalScaledVariableBorrows * variableBorrowIndex) / RAY_BI;
    }
    return 0n;
  }, [totalScaledVariableBorrows, variableBorrowIndex]);

  const poolAvailableLiquidity = useMemo(() => {
    if (totalActualDeposits >= totalActualBorrows) {
        return totalActualDeposits - totalActualBorrows;
    }
    return 0n;
  }, [totalActualDeposits, totalActualBorrows]);

  const availableToBorrowBasedOnCollateral = useMemo(() => {
    // 以资产最小单位计
    if (
      typeof availableBorrowsUSD === 'bigint' &&
      typeof assetPriceUSD === 'bigint' &&
      assetPriceUSD > 0n &&
      typedAssetData
    ) {
      try {
        const assetDecimalsFactor = 10n ** BigInt(assetConfig.decimals);
        return (availableBorrowsUSD * assetDecimalsFactor) / assetPriceUSD;
      } catch (e) {
        return 0n;
      }
    }
    return 0n;
  }, [
    availableBorrowsUSD,
    assetPriceUSD,
    assetConfig.decimals,
    typedAssetData,
  ]);

  // 最终可借此资产的数量 = min(基于抵押品的可借额, 池子流动性)
  const finalAvailableToBorrowThisAsset = useMemo(() => {
    return availableToBorrowBasedOnCollateral < poolAvailableLiquidity
      ? availableToBorrowBasedOnCollateral
      : poolAvailableLiquidity;
  }, [availableToBorrowBasedOnCollateral, poolAvailableLiquidity]);

  const availableToBorrowThisAssetDisplay = useMemo(() => {
    return formatDisplayNumber(
      finalAvailableToBorrowThisAsset,
      assetConfig.decimals,
      DEFAULT_TOKEN_DISPLAY_DECIMALS
    );
  }, [finalAvailableToBorrowThisAsset, assetConfig.decimals]);

  const canBorrowThisAsset = useMemo(() => {
    return (
      finalAvailableToBorrowThisAsset > 0n &&
      (typedAssetData?.isSupported ?? false)
    );
  }, [finalAvailableToBorrowThisAsset, typedAssetData]);

  // --- Input Validations (useEffect hooks) ---
  useEffect(() => {
    if (!userAddress || !isConnected) {
      setDepositInputError('');
      return;
    }
    if (
      depositAmountBigInt > 0n &&
      userTokenBalance &&
      depositAmountBigInt > userTokenBalance.value
    ) {
      setDepositInputError(
        `金额超过钱包余额 (${formatDisplayNumber(
          userTokenBalance.value,
          userTokenBalance.decimals,
          DEFAULT_TOKEN_DISPLAY_DECIMALS
        )})`
      );
    } else if (depositAmount && parseFloat(depositAmount) <= 0) {
      setDepositInputError('金额必须大于0');
    } else {
      setDepositInputError('');
    }
  }, [
    depositAmount,
    depositAmountBigInt,
    userTokenBalance,
    userAddress,
    isConnected,
  ]);

  useEffect(() => {
    if (!userAddress || !isConnected) {
      setWithdrawInputError('');
      return;
    }
    if (
      withdrawAmountBigInt > 0n &&
      typeof userEffectiveDepositInPool === 'bigint' &&
      withdrawAmountBigInt > userEffectiveDepositInPool
    ) {
      setWithdrawInputError(
        `金额超过可取款余额 (${formatDisplayNumber(
          userEffectiveDepositInPool,
          assetConfig.decimals,
          DEFAULT_TOKEN_DISPLAY_DECIMALS
        )})`
      );
    } else if (withdrawAmount && parseFloat(withdrawAmount) <= 0) {
      setWithdrawInputError('金额必须大于0');
    } else {
      setWithdrawInputError('');
    }
  }, [
    withdrawAmount,
    withdrawAmountBigInt,
    userEffectiveDepositInPool,
    assetConfig.decimals,
    userAddress,
    isConnected,
  ]);

  useEffect(() => {
    if (!userAddress || !isConnected) {
      setBorrowInputError('');
      return;
    }
    if (
      borrowAmountBigInt > 0n &&
      typeof healthFactor === 'bigint' &&
      healthFactor <= BigInt(MIN_HEALTH_FACTOR_FOR_BORROW)
    ) {
      setBorrowInputError('健康度过低，借款可能导致清算风险');
    } else if (
      borrowAmountBigInt > 0n &&
      borrowAmountBigInt > finalAvailableToBorrowThisAsset
    ) {
      // 使用 finalAvailableToBorrowThisAsset
      setBorrowInputError(
        `金额超过此资产可借上限 (${availableToBorrowThisAssetDisplay})`
      );
    } else if (borrowAmount && parseFloat(borrowAmount) <= 0) {
      setBorrowInputError('金额必须大于0');
    } else {
      setBorrowInputError('');
    }
  }, [
    borrowAmount,
    borrowAmountBigInt,
    finalAvailableToBorrowThisAsset,
    availableToBorrowThisAssetDisplay,
    healthFactor,
    userAddress,
    isConnected,
  ]);

  useEffect(() => {
    if (!userAddress || !isConnected) {
      setRepayInputError('');
      return;
    }
    const formattedWalletBalance = userTokenBalance
      ? formatDisplayNumber(
          userTokenBalance.value,
          userTokenBalance.decimals,
          DEFAULT_TOKEN_DISPLAY_DECIMALS
        )
      : 'N/A';
    const formattedBorrowBalance =
      typeof userAssetBorrowBalance === 'bigint'
        ? formatDisplayNumber(
            userAssetBorrowBalance,
            assetConfig.decimals,
            DEFAULT_TOKEN_DISPLAY_DECIMALS
          )
        : 'N/A';

    if (
      repayAmountBigInt > 0n &&
      userTokenBalance &&
      repayAmountBigInt > userTokenBalance.value
    ) {
      setRepayInputError(`金额超过钱包余额 (${formattedWalletBalance})`);
    } else if (
      repayAmountBigInt > 0n &&
      typeof userAssetBorrowBalance === 'bigint' &&
      repayAmountBigInt > userAssetBorrowBalance &&
      repayAmount.toUpperCase() !== 'MAX'
    ) {
      setRepayInputError(`金额超过需还款总额 (${formattedBorrowBalance})`);
    } else if (
      repayAmount &&
      parseFloat(repayAmount) <= 0 &&
      repayAmount.toUpperCase() !== 'MAX'
    ) {
      setRepayInputError('金额必须大于0');
    } else {
      setRepayInputError('');
    }
  }, [
    repayAmount,
    repayAmountBigInt,
    userTokenBalance,
    userAssetBorrowBalance,
    assetConfig.decimals,
    userAddress,
    isConnected,
  ]);

  const handleGenericTransactionFeedback = (
    actionName: string,
    isTransactionSuccess: boolean,
    isLoadingConfirmation: boolean,
    transactionHash: Address | undefined,
    confirmationError: Error | null,
    submissionError: Error | null,
    setIsLoadingActionState: React.Dispatch<React.SetStateAction<boolean>>,
    clearInputCallback?: () => void,
    resetWriteHook?: () => void
  ) => {
    if (isLoadingConfirmation) return;
    setIsLoadingActionState(false);
    if (isTransactionSuccess && transactionHash) {
      toast.success(
        `${actionName}成功！Tx: ${transactionHash.substring(0, 6)}...`
      );
      refetchAllowance?.();
      refetchUserTokenBalance?.();
      refetchAssetChainData?.();
      refetchUserEffectiveDepositInPool?.();
      refetchUserAssetBorrowBalance?.();
      refetchTotalCollateralUSD?.();
      refetchTotalDebtUSD?.();
      refetchAvailableBorrowsUSD?.();
      refetchHealthFactor?.();
      refetchAssetChainData?.(); // Refetch asset price too
      clearInputCallback?.();
    } else if (confirmationError && transactionHash) {
      toast.error(
        `${actionName}交易失败: ${getErrorMessage(
          confirmationError
        )} (Tx: ${transactionHash.substring(0, 6)}...)`
      );
    } else if (submissionError && !transactionHash) {
      toast.error(`${actionName}提交失败: ${getErrorMessage(submissionError)}`);
    } else if (
      !isTransactionSuccess &&
      transactionHash &&
      !confirmationError &&
      !submissionError
    ) {
      toast.error(
        `${actionName}交易失败或被拒绝 (Tx: ${transactionHash.substring(
          0,
          6
        )}...)`
      );
    }
    resetWriteHook?.();
  };

  useEffect(
    () =>
      handleGenericTransactionFeedback(
        '授权',
        isApprovalSuccess,
        isConfirmingApproval,
        approveTxHash,
        approveConfirmationError,
        approveSubmissionError,
        setIsApproving,
        undefined,
        resetApprove
      ),
    [
      isApprovalSuccess,
      isConfirmingApproval,
      approveTxHash,
      approveConfirmationError,
      approveSubmissionError,
      resetApprove,
    ]
  );
  useEffect(
    () =>
      handleGenericTransactionFeedback(
        '存款',
        isDepositSuccess,
        isConfirmingDeposit,
        depositTxHash,
        depositConfirmationError,
        depositSubmissionError,
        setIsDepositing,
        () => setDepositAmount(''),
        resetDeposit
      ),
    [
      isDepositSuccess,
      isConfirmingDeposit,
      depositTxHash,
      depositConfirmationError,
      depositSubmissionError,
      resetDeposit,
    ]
  );
  useEffect(
    () =>
      handleGenericTransactionFeedback(
        '取款',
        isWithdrawSuccess,
        isConfirmingWithdraw,
        withdrawTxHash,
        withdrawConfirmationError,
        withdrawSubmissionError,
        setIsWithdrawing,
        () => setWithdrawAmount(''),
        resetWithdraw
      ),
    [
      isWithdrawSuccess,
      isConfirmingWithdraw,
      withdrawTxHash,
      withdrawConfirmationError,
      withdrawSubmissionError,
      resetWithdraw,
    ]
  );
  useEffect(
    () =>
      handleGenericTransactionFeedback(
        '借款',
        isBorrowSuccess,
        isConfirmingBorrow,
        borrowTxHash,
        borrowConfirmationError,
        borrowSubmissionError,
        setIsBorrowing,
        () => setBorrowAmount(''),
        resetBorrow
      ),
    [
      isBorrowSuccess,
      isConfirmingBorrow,
      borrowTxHash,
      borrowConfirmationError,
      borrowSubmissionError,
      resetBorrow,
    ]
  );
  useEffect(
    () =>
      handleGenericTransactionFeedback(
        '还款',
        isRepaySuccess,
        isConfirmingRepay,
        repayTxHash,
        repayConfirmationError,
        repaySubmissionError,
        setIsRepaying,
        () => setRepayAmount(''),
        resetRepay
      ),
    [
      isRepaySuccess,
      isConfirmingRepay,
      repayTxHash,
      repayConfirmationError,
      repaySubmissionError,
      resetRepay,
    ]
  );

  const handleApprove = async (
    amountToApprove: bigint,
    _forAction: 'deposit' | 'repay'
  ) => {
    if (!userAddress || amountToApprove <= 0n) {
      toast.warn('请输入有效金额进行授权');
      return;
    }
    setIsApproving(true);
    try {
      await approveAsync({
        address: assetConfig.underlyingAddress,
        abi: assetConfig.erc20Abi as Abi,
        functionName: 'approve',
        args: [LendingPoolContractConfig.address, amountToApprove],
      });
    } catch (e: any) {
      toast.error(`调用授权失败: ${getErrorMessage(e)}`);
      setIsApproving(false);
      resetApprove();
    }
  };

  const handleDeposit = async () => {
    if (depositInputError || !userAddress || depositAmountBigInt <= 0n) {
      toast.warn(depositInputError || '请输入有效的存款金额');
      return;
    }
    const needsApproval =
      typeof allowance !== 'bigint' || allowance < depositAmountBigInt;
    if (needsApproval) {
      if (isApproving) return;
      await handleApprove(depositAmountBigInt, 'deposit');
      toast.info('请在授权成功后再点击存款按钮。');
      return;
    }
    setIsDepositing(true);
    try {
      await depositAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'deposit',
        args: [assetConfig.underlyingAddress, depositAmountBigInt],
      });
    } catch (e: any) {
      toast.error(`调用存款失败: ${getErrorMessage(e)}`);
      setIsDepositing(false);
      resetDeposit();
    }
  };

  const handleWithdraw = async () => {
    if (withdrawInputError || !userAddress || withdrawAmountBigInt <= 0n) {
      toast.warn(withdrawInputError || '请输入有效的取款金额');
      return;
    }
    setIsWithdrawing(true);
    try {
      await withdrawAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'withdraw',
        args: [assetConfig.underlyingAddress, withdrawAmountBigInt],
      });
    } catch (e: any) {
      toast.error(`调用取款失败: ${getErrorMessage(e)}`);
      setIsWithdrawing(false);
      resetWithdraw();
    }
  };

  const handleBorrow = async () => {
    if (borrowInputError || !userAddress || borrowAmountBigInt <= 0n) {
      toast.warn(borrowInputError || '请输入有效的借款金额');
      return;
    }
    if (
      typeof healthFactor === 'bigint' &&
      healthFactor <= BigInt(MIN_HEALTH_FACTOR_FOR_BORROW)
    ) {
      toast.warn(
        `健康度 (${healthFactorDisplay}) 过低，借款可能导致清算风险。`
      );
      return;
    }
    if (borrowAmountBigInt > finalAvailableToBorrowThisAsset) {
      // 使用 finalAvailableToBorrowThisAsset
      toast.warn(
        `借款金额超过此资产可借上限 (${availableToBorrowThisAssetDisplay})`
      );
      return;
    }
    setIsBorrowing(true);
    try {
      await borrowAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'borrow',
        args: [assetConfig.underlyingAddress, borrowAmountBigInt],
      });
    } catch (e: any) {
      toast.error(`调用借款失败: ${getErrorMessage(e)}`);
      setIsBorrowing(false);
      resetBorrow();
    }
  };

  const handleRepay = async () => {
    if (
      repayInputError ||
      !userAddress ||
      (repayAmountBigInt <= 0n && repayAmount.toUpperCase() !== 'MAX')
    ) {
      toast.warn(repayInputError || '请输入有效的还款金额');
      return;
    }
    let amountToRepay = repayAmountBigInt;
    if (repayAmount.toUpperCase() === 'MAX') {
      if (
        typeof userAssetBorrowBalance === 'bigint' &&
        userAssetBorrowBalance > 0n
      ) {
        amountToRepay = userAssetBorrowBalance;
      } else {
        toast.info('当前没有该资产的借款需要偿还。');
        return;
      }
    }
    if (amountToRepay <= 0n) {
      toast.warn('还款金额必须大于0。');
      return;
    }
    const needsApproval =
      typeof allowance !== 'bigint' || allowance < amountToRepay;
    if (needsApproval) {
      if (isApproving) return;
      await handleApprove(amountToRepay, 'repay');
      toast.info('请在授权成功后再点击还款按钮。');
      return;
    }
    setIsRepaying(true);
    try {
      await repayAsync({
        address: LendingPoolContractConfig.address,
        abi: LendingPoolContractConfig.abi as Abi,
        functionName: 'repay',
        args: [assetConfig.underlyingAddress, amountToRepay],
      });
    } catch (e: any) {
      toast.error(`调用还款失败: ${getErrorMessage(e)}`);
      setIsRepaying(false);
      resetRepay();
    }
  };

  const isLoadingAnyUserData =
    isConnected &&
    (isLoadingTotalCollateralUSD ||
      isLoadingTotalDebtUSD ||
      isLoadingAvailableBorrowsUSD ||
      isLoadingHealthFactor ||
      isLoadingAssetPrice ||
      userTokenBalance === undefined ||
      userEffectiveDepositInPool === undefined ||
      userAssetBorrowBalance === undefined);
  const isLoadingCriticalDisplayData =
    isLoadingAssetData || isLoadingAnyUserData;

  if (isLoadingCriticalDisplayData && activeAction !== null) {
    return (
      <div className={styles.assetCard}>
        <div className={styles.loadingOverlay}>
          <span className={styles.dotFlashing}></span>
          <p>加载数据中...</p>
        </div>
      </div>
    );
  }
  if (errorAssetData) {
    return (
      <div className={styles.assetCard}>
        <p className={styles.errorMessage}>
          加载资产数据失败: {getErrorMessage(errorAssetData)}
        </p>
      </div>
    );
  }
  if (!typedAssetData && activeAction !== null) {
    return (
      <div className={styles.assetCard}>
        <p>无法获取 {assetConfig.symbol} 的资产数据。</p>
      </div>
    );
  }

  const { 
    aTokenAddress,
    // 解构更多资产参数用于显示
    ltv: assetLtvBps, 
    liquidationThreshold: assetLiqThresholdBps,
    reserveFactor: assetReserveFactorBps,
    liquidationBonus: assetLiqBonusBps} = typedAssetData || {};


  const isAnyActionLoading =
    isApproving ||
    isDepositing ||
    isWithdrawing ||
    isBorrowing ||
    isRepaying ||
    isConfirmingApproval ||
    isConfirmingDeposit ||
    isConfirmingWithdraw ||
    isConfirmingBorrow ||
    isConfirmingRepay;

  const getButtonText = (
    actionText: string,
    isSubmitting: boolean,
    isConfirming: boolean
  ) => {
    if (isConfirming)
      return (
        <>
          <span>确认中</span> <span className={styles.dotFlashing}></span>
        </>
      );
    if (isSubmitting)
      return (
        <>
          <span>处理中</span> <span className={styles.dotFlashing}></span>
        </>
      );
    return actionText;
  };
  const getApproveButtonText = (
    defaultText: string,
    isSubmittingApproval: boolean,
    isConfirmingUserApproval: boolean
  ) => {
    if (isConfirmingUserApproval)
      return (
        <>
          <span>授权确认中</span> <span className={styles.dotFlashing}></span>
        </>
      );
    if (isSubmittingApproval)
      return (
        <>
          <span>授权处理中</span> <span className={styles.dotFlashing}></span>
        </>
      );
    return defaultText;
  };

  return (
    <div className={styles.assetCard}>
      <div className={styles.assetHeader}>
        <h3>
          {assetConfig.symbol}
          {aTokenAddress && aTokenAddress !== '0x0000000000000000000000000000000000000000'
            ? <span className={styles.aTokenInfo}> (aToken: {aTokenAddress.substring(0, 6)}...{aTokenAddress.substring(aTokenAddress.length - 4)})</span>
            : ''}
        </h3>
      </div>

      <div className={styles.assetInfoGrid}>
        <div className={styles.infoItem}><span className={styles.infoLabel}>存款 APY:</span> <span className={styles.apyRate}>{depositAPYDisplay}</span></div>
        <div className={styles.infoItem}><span className={styles.infoLabel}>借款 APR:</span> <span className={styles.aprRate}>{variableBorrowAPRDisplay}</span></div>
        
        {/* 新增资产参数显示 */}
        {typeof assetLtvBps === 'bigint' && <div className={styles.infoItem}><span className={styles.infoLabel}>LTV:</span> <span>{(Number(assetLtvBps) / Number(PERCENTAGE_FACTOR_BPS_DIVISOR)).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%</span></div>}
        {typeof assetLiqThresholdBps === 'bigint' && <div className={styles.infoItem}><span className={styles.infoLabel}>清算门槛:</span> <span>{(Number(assetLiqThresholdBps) / Number(PERCENTAGE_FACTOR_BPS_DIVISOR)).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%</span></div>}
        {typeof assetReserveFactorBps === 'bigint' && <div className={styles.infoItem}><span className={styles.infoLabel}>储备因子:</span> <span>{(Number(assetReserveFactorBps) / Number(PERCENTAGE_FACTOR_BPS_DIVISOR)).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%</span></div>}
        {typeof assetLiqBonusBps === 'bigint' && <div className={styles.infoItem}><span className={styles.infoLabel}>清算奖励:</span> <span>{(Number(assetLiqBonusBps) / Number(PERCENTAGE_FACTOR_BPS_DIVISOR)).toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%</span></div>}
        
        {isConnected && (
          <>
            <div className={styles.infoItem}><span className={styles.infoLabel}>健康度:</span> <span className={healthFactorDisplay && parseFloat(healthFactorDisplay) < 1.1 ? styles.healthFactorLow : styles.healthFactorGood}>{healthFactorDisplay}</span></div>
            <div className={styles.infoItem}><span className={styles.infoLabel}>总抵押 (USD):</span> <span>{formatDisplayNumber(totalCollateralUSD, ORACLE_PRICE_DECIMALS, USD_DISPLAY_DECIMALS)}</span></div>
            <div className={styles.infoItem}><span className={styles.infoLabel}>总借款 (USD):</span> <span>{formatDisplayNumber(totalDebtUSD, ORACLE_PRICE_DECIMALS, USD_DISPLAY_DECIMALS)}</span></div>
          </>
        )}
      </div>
      <hr className={styles.divider} />

      {isConnected ? (
        <>
          <div className={styles.userInfoGrid}>
            <div className={styles.infoItem}><span className={styles.infoLabel}>钱包余额:</span> <span>{userTokenBalance ? `${formatDisplayNumber(userTokenBalance.value, userTokenBalance.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} ${userTokenBalance.symbol}` : 'N/A'}</span></div>
            <div className={styles.infoItem}><span className={styles.infoLabel}>已存入 (此资产):</span> <span>{typeof userEffectiveDepositInPool === 'bigint' ? `${formatDisplayNumber(userEffectiveDepositInPool, assetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} ${assetConfig.symbol}` : '0.00'}</span></div>
            <div className={styles.infoItem}><span className={styles.infoLabel}>已借款 (此资产):</span> <span>{typeof userAssetBorrowBalance === 'bigint' ? `${formatDisplayNumber(userAssetBorrowBalance, assetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} ${assetConfig.symbol}` : '0.00'}</span></div>
            <div className={styles.infoItem}><span className={styles.infoLabel}>池子可用流动性:</span> <span>{formatDisplayNumber(poolAvailableLiquidity, assetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} {assetConfig.symbol}</span></div>
          </div>
          <hr className={styles.divider} />

          <div className={styles.actionToggleButtons}>
            <button onClick={() => setActiveAction('deposit')} className={`${styles.toggleButton} ${activeAction === 'deposit' ? styles.active : ''}`}>存款</button>
            <button onClick={() => setActiveAction('withdraw')} className={`${styles.toggleButton} ${activeAction === 'withdraw' ? styles.active : ''}`}>取款</button>
            <button onClick={() => setActiveAction('borrow')} className={`${styles.toggleButton} ${activeAction === 'borrow' ? styles.active : ''}`}>借款</button>
            <button onClick={() => setActiveAction('repay')} className={`${styles.toggleButton} ${activeAction === 'repay' ? styles.active : ''}`}>还款</button>
          </div>

          {activeAction === 'deposit' && (
            <div className={styles.actionSection}>
              <h5>存款 {assetConfig.symbol}</h5>
              <input type="number" value={depositAmount} onChange={(e) => setDepositAmount(e.target.value)} placeholder={`输入存款数量`} disabled={isAnyActionLoading}/>
              {depositInputError && <p className={styles.inputError}>{depositInputError}</p>}
              <button onClick={handleDeposit} disabled={isAnyActionLoading || !!depositInputError || depositAmountBigInt <= 0n} className={styles.actionButton}>
                {(isApproving || isConfirmingApproval) 
                    ? getApproveButtonText('授权并存款', isApproving, isConfirmingApproval) 
                    : (isDepositing || isConfirmingDeposit) 
                        ? getButtonText('存款', isDepositing, isConfirmingDeposit) 
                        : (typeof allowance !== 'bigint' || allowance < depositAmountBigInt) && depositAmountBigInt > 0n 
                            ? '授权并存款' 
                            : '存款'}
              </button>
            </div>
          )}

          {activeAction === 'withdraw' && (
             <div className={styles.actionSection}>
              <h5>取款 {assetConfig.symbol}</h5>
              <input type="number" value={withdrawAmount} onChange={(e) => setWithdrawAmount(e.target.value)} placeholder={`输入取款数量`} disabled={isAnyActionLoading}/>
              {withdrawInputError && <p className={styles.inputError}>{withdrawInputError}</p>}
              <button onClick={handleWithdraw} disabled={isAnyActionLoading || !!withdrawInputError || withdrawAmountBigInt <= 0n} className={styles.actionButton}>
                {getButtonText('取款', isWithdrawing, isConfirmingWithdraw)}
              </button>
            </div>
          )}

          {activeAction === 'borrow' && (
            <div className={styles.actionSection}>
              <h5>借款 {assetConfig.symbol}</h5>
              <div className={styles.borrowInfo}>
                <p><span className={styles.infoLabel}>总可借额度 (USD):</span> {formatDisplayNumber(availableBorrowsUSD, ORACLE_PRICE_DECIMALS, USD_DISPLAY_DECIMALS)} USD</p>
                <p><span className={styles.infoLabel}>此资产可借上限:</span> {isLoadingAssetPrice ? (<span className={styles.dotFlashing}></span>) : availableToBorrowThisAssetDisplay} </p>
                 <p><span className={styles.infoLabel}>池子当前可用:</span> {formatDisplayNumber(poolAvailableLiquidity, assetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} {assetConfig.symbol}</p>
              </div>
              <input type="number" value={borrowAmount} onChange={(e) => setBorrowAmount(e.target.value)} placeholder={`输入借款数量`} disabled={isAnyActionLoading || isLoadingAssetPrice}/>
              {borrowInputError && <p className={styles.inputError}>{borrowInputError}</p>}
              <button onClick={handleBorrow} disabled={isAnyActionLoading || !!borrowInputError || borrowAmountBigInt <= 0n || !canBorrowThisAsset || isLoadingAssetPrice } className={styles.actionButton}>
                 {getButtonText('借款', isBorrowing, isConfirmingBorrow)}
              </button>
            </div>
          )}

          {activeAction === 'repay' && (
            <div className={styles.actionSection}>
              <h5>还款 {assetConfig.symbol}</h5>
               <p><span className={styles.infoLabel}>当前借款额:</span> {typeof userAssetBorrowBalance === 'bigint' ? `${formatDisplayNumber(userAssetBorrowBalance, assetConfig.decimals, DEFAULT_TOKEN_DISPLAY_DECIMALS)} ${assetConfig.symbol}` : '0.00'}</p>
              <input type="number" value={repayAmount} onChange={(e) => { if(e.target.value.toUpperCase() === 'MAX' && typeof userAssetBorrowBalance === 'bigint' && userAssetBorrowBalance > 0n) { setRepayAmount(formatUnits(userAssetBorrowBalance, assetConfig.decimals))} else { setRepayAmount(e.target.value)}}} placeholder={`输入还款数量 (或输入 'MAX')`} disabled={isAnyActionLoading}/>
              {repayInputError && <p className={styles.inputError}>{repayInputError}</p>}
              <button onClick={handleRepay} disabled={isAnyActionLoading || !!repayInputError || repayAmountBigInt <= 0n} className={styles.actionButton}>
                {(isApproving || isConfirmingApproval)
                    ? getApproveButtonText('授权并还款', isApproving, isConfirmingApproval)
                    : (isRepaying || isConfirmingRepay)
                        ? getButtonText('还款', isRepaying, isConfirmingRepay)
                        : (typeof allowance !== 'bigint' || allowance < repayAmountBigInt) && repayAmountBigInt > 0n
                            ? '授权并还款'
                            : '还款'}
              </button>
            </div>
          )}
        </>
      ) : (
        <p className={styles.connectWalletPrompt}>请先连接钱包以进行操作。</p>
      )}
    </div>
  );
}

export default AssetCard;
