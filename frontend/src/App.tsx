// src/App.tsx
import React , {type JSX} from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import './App.css'; 

import Header from './components/layout/Header'; 
import Footer from './components/layout/Footer'; 
import MarketPage from './pages/MarketPage'; 
import LiquidationPage from './pages/LiquidationPage'; 
import FlashLoanPage from './pages/FlashLoanPage'; 
import AdminPage from './pages/AdminPage'; // <--- 导入管理员页面
// import NotFoundPage from './pages/NotFoundPage'; 

import { useAccount } from 'wagmi'; 
import { toast } from 'react-toastify'; 

interface ProtectedRouteProps {
  children: JSX.Element;
  requireOwner?: boolean; // 新增：可选的 prop，用于检查是否需要 owner 权限
}

const ProtectedRoute: React.FC<ProtectedRouteProps> = ({ children, requireOwner = false }) => {
  const { address: connectedUserAddress, isConnected } = useAccount();
  const location = useLocation();

  // 1. 检查钱包是否连接
  if (!isConnected) {
    toast.info("请先连接钱包以访问此页面。", { toastId: 'connectWalletRedirect' });
    return <Navigate to="/market" state={{ from: location }} replace />;
  }

  // 2. 如果需要 owner 权限，则检查是否是 owner
  // 注意：这里我们还没有 Configurator owner 的数据，AdminPage 内部会自己获取并判断
  // 这个 ProtectedRoute 可以进一步扩展，如果能从 context 或 props 获取 owner 地址的话
  // 目前，AdminPage 内部会处理 owner 权限的显示逻辑

  return children;
};


function App() {
  return (
    <div className="app-container"> 
      <Header /> 
      <main className="main-content"> 
        <Routes>
          <Route path="/" element={<MarketPage />} />
          <Route path="/market" element={<MarketPage />} />
          <Route 
            path="/liquidation" 
            element={
              <ProtectedRoute>
                <LiquidationPage />
              </ProtectedRoute>
            } 
          />
          <Route 
            path="/flashloan" 
            element={
              <ProtectedRoute>
                <FlashLoanPage />
              </ProtectedRoute>
            } 
          />
          <Route 
            path="/admin" 
            element={
              <ProtectedRoute> 
                <AdminPage />
              </ProtectedRoute>
            } 
          />
          {/* <Route path="*" element={<NotFoundPage />} /> */} 
        </Routes>
      </main>
      <Footer />
    </div>
  );
}

export default App;
