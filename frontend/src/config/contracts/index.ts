import { type Address, type Abi } from 'viem';

// 1. ABI 导入
// 确保这些 JSON 文件存在于 ./abis/ 目录下，并且内容是正确的合约 ABI
import LendingPoolAbiJson from './abis/LendingPool.json';
import ATokenAbiJson from './abis/AToken.json';
import Erc20AbiJson from './abis/ERC20.json';
import PriceOracleAbiJson from './abis/PriceOracle.json';
import ConfiguratorAbiJson from './abis/Configurator.json';

// --- 2. 核心合约地址常量 ---
// 请确保这些地址是你最新部署到 Anvil (或其他网络) 的正确地址
export const LENDING_POOL_ADDRESS =
  '0x0165878A594ca255338adfa4d48449f69242Eb8F' as const;
export const CONFIGURATOR_ADDRESS =
  '0x5FC8d32690cc91D4c39d9d3abcBD16989F875707' as const;
export const PRICE_ORACLE_ADDRESS =
  '0x5FbDB2315678afecb367f032d93F642f64180aa3' as const;

// Mock ERC20 代币地址 (这些应该与你部署脚本中的一致)
export const MDAI_ADDRESS =
  '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512' as const;
export const MUSDC_ADDRESS =
  '0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0' as const;

// --- 3. TypeScript 类型定义 ---

// 从 LendingPool.getAssetData 返回的结构体类型
export interface GetAssetDataReturnType {
  isSupported: boolean;
  decimals: number; // Solidity uint8 -> TS number
  ltv: bigint;
  liquidationThreshold: bigint;
  interestRateStrategy: Address;
  reserveFactor: bigint;
  liquidationBonus: bigint;
  liquidityIndex: bigint;
  variableBorrowIndex: bigint;
  lastUpdateTimestamp: bigint;
  totalScaledDeposits: bigint;
  totalScaledVariableBorrows: bigint;
  currentTotalReserves: bigint;
  aTokenAddress: Address;
  currentAnnualLiquidityRateRAY: bigint;
  currentAnnualVariableBorrowRateRAY: bigint;
}

// (如果需要) 从 LendingPool.getUserAccountData 返回的结构体类型
// 你目前是单个函数获取，所以这个可能不是一个大的组合结构体
export interface GetUserAccountDataReturnType {
  totalCollateralUSD: bigint;
  totalDebtUSD: bigint;
  availableBorrowsUSD: bigint;
  // currentLiquidationThreshold: bigint; // 这个通常是针对单个资产或加权的
  healthFactor: bigint;
  // ltv: bigint; // 这个通常是针对单个资产或加权的
}

// 资产配置接口
export interface AssetConfig {
  symbol: string;
  name: string;
  decimals: number;
  underlyingAddress: Address;
  erc20Abi: Abi; // 使用 Viem 的 Abi 类型
  aTokenAddress?: Address; // aToken 地址是动态获取的，可以设为可选
  aTokenAbi?: Abi;
  isDemo?: boolean;
  iconSymbol?: string;
  color?: string;
  // 你可能还想在这里加入从 getAssetData 获取的静态配置，如 ltv, liquidationThreshold 等，
  // 但这些也可以在使用时从 GetAssetDataReturnType 中获取。
  // 为了演示，我们保持简单。
  liquidationBonus?: bigint; // 从你的 Solidity 结构体中，这个是 uint256
}

// --- 4. 支持的资产配置 ---
export const SUPPORTED_ASSETS_CONFIG: AssetConfig[] = [
  {
    symbol: 'mDAI',
    name: 'Mock DAI (可交互)',
    decimals: 18, // 与你 MockDAI 设置的一致
    underlyingAddress: MDAI_ADDRESS,
    erc20Abi: Erc20AbiJson.abi as Abi, // 类型断言为 Abi
    aTokenAbi: ATokenAbiJson.abi as Abi, // 类型断言为 Abi
    isDemo: true,
    iconSymbol: 'mD',
    color: '#F5AC37',
    liquidationBonus: 500n, // 示例值，与你 Deploy.s.sol 中的 DAI_LIQ_BONUS 一致 (5%)
  },
  {
    symbol: 'mUSDC',
    name: 'Mock USDC (可交互)',
    decimals: 6, // 与你 MockUSDC 设置的一致
    underlyingAddress: MUSDC_ADDRESS,
    erc20Abi: Erc20AbiJson.abi as Abi,
    aTokenAbi: ATokenAbiJson.abi as Abi,
    isDemo: true,
    iconSymbol: 'mU',
    color: '#2775CA',
    liquidationBonus: 500n, // 示例值，与你 Deploy.s.sol 中的 USDC_LIQ_BONUS 一致 (5%)
  },

  // 仅浏览的真实代币 (地址是主网地址，在本地 Anvil 上无法直接交互，除非你 fork 主网)
  {
    symbol: 'ETH',
    name: 'Ethereum (仅浏览)',
    decimals: 18,
    underlyingAddress: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'ETH',
    color: '#627EEA',
  },
  {
    symbol: 'USDC',
    name: 'USD Coin (仅浏览)',
    decimals: 6,
    underlyingAddress: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'USDC',
    color: '#2775CA',
  },
  {
    symbol: 'DAI',
    name: 'Dai Stablecoin (仅浏览)',
    decimals: 18,
    underlyingAddress: '0x6B175474E89094C44Da98b954EedeAC495271d0F' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'DAI',
    color: '#F5AC37',
  },
  {
    symbol: 'USDT',
    name: 'Tether USD (仅浏览)',
    decimals: 6,
    underlyingAddress: '0xdAC17F958D2ee523a2206206994597C13D831ec7' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'USDT',
    color: '#26A17B',
  },
  {
    symbol: 'BNB',
    name: 'Binance Coin (仅浏览)',
    decimals: 18,
    underlyingAddress: '0xB8c77482e45F1F44dE1745F52C74426C631bDD52' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'BNB',
    color: '#F3BA2F',
  },
  {
    symbol: 'MATIC',
    name: 'Polygon (仅浏览)',
    decimals: 18,
    underlyingAddress: '0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'MATIC',
    color: '#8247E5',
  },
  {
    symbol: 'LINK',
    name: 'Chainlink (仅浏览)',
    decimals: 18,
    underlyingAddress: '0x514910771AF9Ca656af840dff83E8264EcF986CA' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'LINK',
    color: '#2A5ADA',
  },
  {
    symbol: 'UNI',
    name: 'Uniswap (仅浏览)',
    decimals: 18,
    underlyingAddress: '0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984' as Address,
    erc20Abi: Erc20AbiJson.abi as Abi,
    isDemo: false,
    iconSymbol: 'UNI',
    color: '#FF007A',
  },
];

// --- 5. 导出给 Wagmi 使用的合约配置对象 ---
export const LendingPoolContractConfig = {
  address: LENDING_POOL_ADDRESS,
  abi: LendingPoolAbiJson.abi as Abi, // 确保这是最新的 ABI
} as const;

export const PriceOracleContractConfig = {
  address: PRICE_ORACLE_ADDRESS,
  abi: PriceOracleAbiJson.abi as Abi, // 确保这是 PriceOracle 的 ABI
} as const;

export const ConfiguratorContractConfig = {
  address: CONFIGURATOR_ADDRESS,
  abi: ConfiguratorAbiJson.abi as Abi, // 确保这是 Configurator 的 ABI
} as const;

// 通用 ERC20 配置 (可以使用 MockERC20 的 ABI 作为通用 ERC20 ABI)
export function getErc20ContractConfig(tokenAddress: Address) {
  return {
    address: tokenAddress,
    abi: Erc20AbiJson.abi as Abi,
  } as const;
}

// 通用 AToken 配置
export function getATokenContractConfig(aTokenAddr: Address) {
  return {
    address: aTokenAddr,
    abi: ATokenAbiJson.abi as Abi,
  } as const;
}
