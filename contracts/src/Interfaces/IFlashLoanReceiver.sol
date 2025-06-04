// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IFlashLoanReceiver {
  /**
   * @notice 接收闪电贷并执行操作的回调函数。
   * @param initiator 发起闪电贷请求的地址 (LendingPool.flashLoan函数的调用者)。
   * @param asset 借出的资产地址。
   * @param amount 借出的资产数量 (底层资产单位)。
   * @param fee 此次闪电贷需要支付的手续费数量 (底层资产单位)。
   * @param params 发起者传入的额外参数，可用于指导接收合约的操作。
   * @return bool 必须返回 true 表示操作成功且资金已准备好归还。
   */

  function executeOperation(
    address initiator,
    address asset,
    uint256 amount,
    uint256 fee,
    bytes calldata params
  ) external returns (bool);
}
