import React from 'react';
import LiquidationForm from '@/components/LiquidationForm/LiquidationForm'; // 确保路径正确
import styles from './LiquidationPage.module.css'; // 我们将创建这个 CSS 文件

function LiquidationPage() {
  return (
    <div className={styles.pageContainer}>
      <header className={styles.pageHeader}>
        <h1>清算中心</h1>
        <p>在这里，您可以查看并尝试清算有风险的借贷头寸。</p>
      </header>
      <main className={styles.mainContent}>
        <LiquidationForm />
      </main>
    </div>
  );
}

export default LiquidationPage;
