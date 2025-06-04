import React from 'react';
import FlashLoanForm from '@/components/FlashLoanForm/FlashLoanForm'
import styles from './FlashLoanPage.module.css';

function FlashLoanPage() {
    return (
        <div className={styles.pageContainer}>
            <header className={styles.pageHeader}>
                <h1>闪电贷中心</h1>
                <p>体验在单笔交易中借入并归还资产的强大功能，享受无抵押，低手续费贷款的便捷服务</p>
                <p className={styles.warningNote}>
                <strong>注意:</strong> 这是一个演示功能。实际的闪电贷通常用于更复杂的操作，如套利、抵押品互换等，并需要专门的接收者合约。
                </p>
            </header>
            <main className={styles.mainContent}>
        <FlashLoanForm />
      </main>
    </div>
  );
}

export default FlashLoanPage;