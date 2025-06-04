import React, { useState, useEffect, useMemo } from 'react';
import { useAccount, usePublicClient } from 'wagmi'; // useWatchContractEvent 适用于组件顶层，useEffect 中用 publicClient.watchContractEvent
import {
  type Address,
  formatUnits,
  parseAbiItem,
  type Log,
  type AbiEvent,
  // decodeEventLog, // decodeEventLog is not explicitly used, log.args is provided by watchContractEvent
  // type GetEventArgs, // Removing GetEventArgs
} from 'viem';
import { toast } from 'react-toastify';

import {
  LendingPoolContractConfig,
  SUPPORTED_ASSETS_CONFIG,
  type AssetConfig,
} from '@/config/contracts';
import {
  type TransactionHistoryEntry,
  type TransactionType,
} from '@/types/asset.types';
import styles from './TransactionHistory.module.css';
import { getErrorMessage } from '@/utils/errors';

const MAX_HISTORY_ITEMS = 20;

// 为每个事件的 args 定义更具体的类型
interface DepositedEventArgs {
  asset: Address;
  user: Address;
  amount: bigint;
  scaledAmount: bigint;
  timestamp: bigint;
}
interface WithdrawnEventArgs extends DepositedEventArgs {}
interface BorrowedEventArgs extends DepositedEventArgs {}
interface RepaidEventArgs {
  asset: Address;
  user: Address;
  repayer: Address;
  amount: bigint;
  scaledAmount: bigint;
  timestamp: bigint;
}

// 定义 processLog 返回的统一结构
interface ProcessedLogData {
  assetAddress: Address;
  amount: bigint;
  user: Address;
  timestamp: bigint;
  repayer?: Address;
}

// Log 类型，其中 args 是已知的 (TAbiEvent 用于更精确的 args 类型)
// type TypedEventLog<TAbiEvent extends AbiEvent> = Log<bigint, number, false, TAbiEvent, true, readonly [TAbiEvent], TAbiEvent['name']>;
// 上面的 TypedEventLog 定义可能过于复杂，我们将依赖 watchContractEvent 的类型推断

function TransactionHistory() {
  const { address: userAddress, isConnected } = useAccount();
  const publicClient = usePublicClient();

  const [history, setHistory] = useState<TransactionHistoryEntry[]>([]);
  const [isLoadingHistory, setIsLoadingHistory] = useState<boolean>(false);

  const getAssetSymbol = (assetAddress: Address): string => {
    const asset = SUPPORTED_ASSETS_CONFIG.find(
      (a) => a.underlyingAddress.toLowerCase() === assetAddress.toLowerCase()
    );
    return asset ? asset.symbol : assetAddress.substring(0, 6) + '...';
  };

  const getAssetDecimals = (assetAddress: Address): number => {
    const asset = SUPPORTED_ASSETS_CONFIG.find(
      (a) => a.underlyingAddress.toLowerCase() === assetAddress.toLowerCase()
    );
    return asset ? asset.decimals : 18;
  };

  const eventDefinitions = useMemo(
    () => [
      {
        eventName: 'Deposited' as const,
        type: 'Deposit' as TransactionType,
        abiItem: parseAbiItem(
          'event Deposited(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount, uint256 timestamp)'
        ),
        processLog: (logArgs: DepositedEventArgs): ProcessedLogData => ({
          assetAddress: logArgs.asset,
          amount: logArgs.amount,
          user: logArgs.user,
          timestamp: logArgs.timestamp,
          repayer: undefined,
        }),
      },
      {
        eventName: 'Withdrawn' as const,
        type: 'Withdraw' as TransactionType,
        abiItem: parseAbiItem(
          'event Withdrawn(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount, uint256 timestamp)'
        ),
        processLog: (logArgs: WithdrawnEventArgs): ProcessedLogData => ({
          assetAddress: logArgs.asset,
          amount: logArgs.amount,
          user: logArgs.user,
          timestamp: logArgs.timestamp,
          repayer: undefined,
        }),
      },
      {
        eventName: 'Borrowed' as const,
        type: 'Borrow' as TransactionType,
        abiItem: parseAbiItem(
          'event Borrowed(address indexed asset, address indexed user, uint256 amount, uint256 scaledAmount, uint256 timestamp)'
        ),
        processLog: (logArgs: BorrowedEventArgs): ProcessedLogData => ({
          assetAddress: logArgs.asset,
          amount: logArgs.amount,
          user: logArgs.user,
          timestamp: logArgs.timestamp,
          repayer: undefined,
        }),
      },
      {
        eventName: 'Repaid' as const,
        type: 'Repay' as TransactionType,
        abiItem: parseAbiItem(
          'event Repaid(address indexed asset, address indexed user, address indexed repayer, uint256 amount, uint256 scaledAmount, uint256 timestamp)'
        ),
        processLog: (logArgs: RepaidEventArgs): ProcessedLogData => ({
          assetAddress: logArgs.asset,
          amount: logArgs.amount,
          user: logArgs.user,
          timestamp: logArgs.timestamp,
          repayer: logArgs.repayer,
        }),
      },
    ],
    []
  );

  useEffect(() => {
    if (!isConnected || !userAddress || !publicClient) {
      setHistory([]);
      return;
    }

    setIsLoadingHistory(true);
    const unwatchFunctions: (() => void)[] = [];

    eventDefinitions.forEach((eventDef) => {
      if (!publicClient) return;

      try {
        const unwatch = publicClient.watchContractEvent({
          address: LendingPoolContractConfig.address,
          abi: [eventDef.abiItem],
          eventName: eventDef.eventName,
          args:
            eventDef.eventName === 'Repaid'
              ? { user: userAddress }
              : ({ user: userAddress } as any),
          onLogs: (logs) => {
            logs.forEach((log) => {
              if (
                !log.args ||
                !log.transactionHash ||
                !log.logIndex ||
                !log.eventName
              ) {
                console.warn(
                  'Log missing essential fields (args, transactionHash, logIndex, or eventName): ',
                  log
                );
                return;
              }

              const processedData = eventDef.processLog(log.args as any);

              let isCurrentUserEvent = false;
              if (log.eventName === 'Repaid') {
                isCurrentUserEvent =
                  processedData.user?.toLowerCase() ===
                    userAddress.toLowerCase() ||
                  processedData.repayer?.toLowerCase() ===
                    userAddress.toLowerCase();
              } else {
                isCurrentUserEvent =
                  processedData.user?.toLowerCase() ===
                  userAddress.toLowerCase();
              }
              if (!isCurrentUserEvent) return;

              if (
                history.some(
                  (entry) =>
                    entry.id === `${log.transactionHash}-${log.logIndex}`
                )
              ) {
                return;
              }

              const assetSymbol = getAssetSymbol(processedData.assetAddress);
              const assetDecimals = getAssetDecimals(
                processedData.assetAddress
              );
              const dateFormatted = new Date(
                Number(processedData.timestamp) * 1000
              ).toLocaleString();
              const amountFormatted = formatUnits(
                processedData.amount,
                assetDecimals
              );

              const newEntry: TransactionHistoryEntry = {
                id: `${log.transactionHash}-${log.logIndex}`,
                type: eventDef.type,
                assetSymbol,
                assetAddress: processedData.assetAddress,
                amount: processedData.amount,
                amountFormatted,
                timestamp: processedData.timestamp,
                dateFormatted,
                txHash: log.transactionHash as Address,
              };

              setHistory((prevHistory) => {
                if (prevHistory.some((entry) => entry.id === newEntry.id)) {
                  return prevHistory;
                }
                const updatedHistory = [newEntry, ...prevHistory];
                return updatedHistory.slice(0, MAX_HISTORY_ITEMS);
              });
            });
          },
          onError: (error: Error) => {
            console.error(
              `Error watching ${eventDef.eventName} events:`,
              error
            );
            toast.error(
              `监听 ${eventDef.eventName} 事件出错: ${getErrorMessage(error)}`
            );
          },
        });
        unwatchFunctions.push(unwatch);
      } catch (error) {
        console.error(
          `Failed to set up watcher for ${eventDef.eventName}:`,
          error
        );
      }
    });

    const timer = setTimeout(() => setIsLoadingHistory(false), 1000);

    return () => {
      clearTimeout(timer);
      unwatchFunctions.forEach((unwatch) => {
        if (typeof unwatch === 'function') {
          unwatch();
        }
      });
    };
  }, [isConnected, userAddress, publicClient, eventDefinitions, history]);

  if (!isConnected) {
    return null;
  }

  return (
    <div className={styles.historyContainer}>
      <h3>交易历史</h3>
      {isLoadingHistory && history.length === 0 && <p>正在加载历史记录...</p>}
      {!isLoadingHistory && history.length === 0 && <p>暂无交易记录。</p>}
      {history.length > 0 && (
        <table className={styles.historyTable}>
          <thead>
            <tr>
              <th>类型</th>
              <th>资产</th>
              <th>数量</th>
              <th>日期</th>
              <th>交易哈希</th>
            </tr>
          </thead>
          <tbody>
            {history.map((entry) => (
              <tr key={entry.id}>
                <td>{entry.type}</td>
                <td>{entry.assetSymbol}</td>
                <td>{entry.amountFormatted}</td>
                <td>{entry.dateFormatted}</td>
                <td>
                  {entry.txHash ? (
                    <a
                      href={
                        publicClient?.chain?.blockExplorers?.default.url
                          ? `${publicClient.chain.blockExplorers.default.url}/tx/${entry.txHash}`
                          : `#${entry.txHash}`
                      }
                      target="_blank"
                      rel="noopener noreferrer"
                      className={styles.txLink}
                    >
                      {`${entry.txHash.substring(
                        0,
                        6
                      )}...${entry.txHash.substring(entry.txHash.length - 4)}`}
                    </a>
                  ) : (
                    'N/A'
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default TransactionHistory;
