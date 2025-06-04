// src/config/providers.ts
import { createConfig, http } from 'wagmi';
import { mainnet, sepolia, localhost } from 'wagmi/chains'; // localhost 可以作为 Anvil 的基础
import { QueryClient } from '@tanstack/react-query';
import { type Chain } from 'viem';

export const projectId = 'b6f532b347fcb41b97f3de4dd3da6f16'; // 确保这是你的 WalletConnect Project ID

// 1. 定义 Anvil 本地链
// 你可以基于 wagmi/chains 提供的 localhost 进行自定义，或者完全手动定义
// 确保端口号与你实际运行 Anvil 的端口一致 (默认 8545，你之前截图显示的是 8555)
const anvilPort = 8545; // <--- 从你的截图看，Anvil 运行在 8555 端口
const anvilRpcUrl = `http://127.0.0.1:${anvilPort}`;

export const anvilChain: Chain = {
  ...localhost, // 继承 localhost 的一些默认设置 (如 id: 1337，但 Anvil 通常是 31337)
  id: 31337,    // Anvil 默认的 Chain ID
  name: 'Anvil Localhost',
  rpcUrls: {
    default: { http: [anvilRpcUrl] },
    public: { http: [anvilRpcUrl] }, // 有时 public 也需要设置
  },
  nativeCurrency: { // 可以自定义原生代币信息
    name: 'Anvil Ether',
    symbol: 'ARETH', // 或者用 ETH
    decimals: 18,
  },
  // blockExplorers: { // 可选：如果你想在UI中显示区块浏览器链接
  //   default: { name: 'Etherscan', url: 'http://localhost:8545' }, // Anvil 本身没有浏览器
  // },
  testnet: true,
};

// 2. 更新 wagmiChains 数组以包含 anvilChain
// 你可以根据开发环境和生产环境选择不同的链
// 例如，在开发时主要使用 anvilChain
export const wagmiChains = [anvilChain, sepolia, mainnet] as const;
// 或者，如果只想在开发时用 Anvil:
// const chainsForDev = [anvilChain, sepolia];
// const chainsForProd = [mainnet, sepolia];
// export const wagmiChains = (import.meta.env.DEV ? chainsForDev : chainsForProd) as readonly [Chain, ...Chain[]];


// 3. 更新 wagmiConfig
export const wagmiConfig = createConfig({
  chains: wagmiChains, // 现在包含了 anvilChain
  transports: {
    [anvilChain.id]: http(anvilRpcUrl), // <--- 为 Anvil 明确指定 transport 和 RPC URL
    [mainnet.id]: http(), // 可以保留，或者如果你有自己的 Mainnet RPC，也可以指定
    [sepolia.id]: http(), // 可以保留，或者如果你有自己的 Sepolia RPC，也可以指定
  },
  // multiInjectedProviderDiscovery: false, // 可选: 如果遇到多个注入钱包的冲突，可以尝试设置
});

export const queryClient = new QueryClient();
