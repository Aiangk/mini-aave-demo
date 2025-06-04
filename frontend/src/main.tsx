// src/main.tsx
import React from 'react';
import ReactDOM from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import App from './App.tsx'; // 你的主应用组件
import './index.css'; // 全局样式
import '@rainbow-me/rainbowkit/styles.css'; // RainbowKit 样式

// 1. 从 providers.ts 导入配置好的实例
import { wagmiConfig, queryClient } from './config/providers'; // 不再需要导入 wagmiChains 给 RainbowKitProvider

// 2. 导入必要的 Provider 组件
import { WagmiProvider } from 'wagmi';
import { QueryClientProvider } from '@tanstack/react-query';
import { RainbowKitProvider, darkTheme } from '@rainbow-me/rainbowkit'; // 导入你选择的主题

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider 
          // chains={wagmiChains} // <--- 移除这一行
          theme={darkTheme({ // 使用你选择的主题和自定义选项
            accentColor: '#607bff', // 示例颜色
            accentColorForeground: 'white',
            borderRadius: 'medium',
            fontStack: 'system',
            overlayBlur: 'small',
          })}
          modalSize="compact" // 可选：设置连接模态框大小
        >
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  </React.StrictMode>
);
