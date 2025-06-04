import { useAccount } from 'wagmi'; // 需要导入 useAccount
import AssetList from '@/components/AssetList/AssetList'; // 假设 AssetList.tsx 在这个路径
import UserAccountOverview from '../components/UserAccountOverview/UserAccountOverview';
import TransactionHistory from '@/components/TransactionHistory/TransactionHistory';

const MarketPage = () => {
  const { address, isConnected } = useAccount();

  return (
    <div className="">
      {' '}
      {/* (可选) MarketPage 容器样式 */}
      <h1>欢迎来到 Mini Aave !</h1>
      {isConnected ? (
        <>
          <p>
            {' '}
            {/* (可选) 样式 */}
            你的钱包地址:{' '}
            <code style={{ fontSize: '0.9em', color: '#aaa' }}>{address}</code>
          </p>
          {/* 在这里渲染用户账户概览组件 */}
          <UserAccountOverview />
          <hr></hr>
          {/* (可选) 分隔线样式 */}
          <AssetList /> {/* 你现有的资产列表和操作卡片 */}
        </>
      ) : (
        <p>请连接你的钱包以查看市场并进行交互。</p>
      )}
      {isConnected && <TransactionHistory />} {/* 仅当连接钱包后显示 */}
    </div>
  );
};

export default MarketPage;
