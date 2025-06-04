import React from 'react';
import { Link, useLocation } from 'react-router-dom'; // <--- 导入 Link 和 useLocation
import { ConnectButton } from '@rainbow-me/rainbowkit';
import '@rainbow-me/rainbowkit/styles.css';
import styles from './Header.module.css'; // 假设你为 Header 创建了 CSS Modules
import { useAccount } from 'wagmi'; // 导入 useAccount 以便根据连接状态显示管理员链接



const Header: React.FC = () => {
  const location = useLocation(); // 获取当前路径信息，用于高亮活动链接
  const { address: connectedUserAddress, isConnected } = useAccount();

  // 实际上，判断是否显示 "管理员" 链接的逻辑最好在 Header 中进行，
  // 或者由 App 组件传递一个 isAdmin 的 prop。
  // 这里我们先简单地在连接钱包后就显示链接，AdminPage 内部会做权限校验。

  return (
    <header className={styles.appHeader}>
      <div className={styles.logoAndNav}>
        <Link to="/" className={styles.logo}>
          Mini Aave {/* 你可以替换成 Logo 图片 */}
        </Link>
        <nav className={styles.navigation}>
          <Link
            to="/market"
            className={`${styles.navLink} ${
              location.pathname === '/market' || location.pathname === '/'
                ? styles.activeLink
                : ''
            }`}
          >
            市场资产
          </Link>
          <Link
            to="/liquidation"
            className={`${styles.navLink} ${
              location.pathname === '/liquidation' ? styles.activeLink : ''
            }`}
          >
            清算中心
          </Link>
          <Link
            to="/flashloan"
            className={`${styles.navLink} ${location.pathname === '/flashloan' ? styles.activeLink : ''}`}
            >
              闪电贷
            </Link>
            {isConnected && (
            <Link 
              to="/admin" 
              className={`${styles.navLink} ${location.pathname === '/admin' ? styles.activeLink : ''}`}
            >
              管理员
            </Link>
          )}
          {/* 在这里可以添加更多导航链接 */}
        </nav>
      </div>
      <div className={styles.walletConnection}>
        <ConnectButton
          accountStatus="full"
          showBalance={true}
          chainStatus="icon"
        />
      </div>
    </header>
  );
};

export default Header;
