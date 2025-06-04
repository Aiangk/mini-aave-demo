//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IFlashLoanReceiver} from "../Interfaces/IFlashLoanReceiver.sol"; // 确保路径正确
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // 用于安全转账
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // 可选，如果需要管理权限
import "forge-std/console.sol";
contract FlashLoanReceiverExample is IFlashLoanReceiver, Ownable {
    using SafeERC20 for IERC20;
    address public immutable lendingPool;

    event LoanReceivedAndRepaid(
        address initiator,
        address asset,
        uint256 amount,
        uint256 fee
    );

    constructor(address _lendingPoolAddress) Ownable(msg.sender) {
        require(_lendingPoolAddress != address(0), "Invalid LendingPool address");
        lendingPool = _lendingPoolAddress;
    }

     /**
     * @dev This function is called by the LendingPool after a flash loan has been made.
     * It needs to repay the `amount` + `fee` to the LendingPool.
     */
    function executeOperation(
        address _initiator,
        address _asset,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _params // 在这个简单用例中我们不使用 _params
    ) external override returns (bool) {

        console.log("FlashLoanReceiverExample: executeOperation called.");
    console.log("Asset:", _asset);
    console.log("Amount received:", _amount);
    console.log("Fee:", _fee);
    console.log("LendingPool (expected caller):", lendingPool);
    console.log("Actual caller (msg.sender):", msg.sender);
        // 确保调用者是 LendingPool
        require(msg.sender == lendingPool, "FlashLoanReceiverExample: Caller is not the LendingPool");
        
        // 在这里，合约已经收到了 _amount 数量的 _asset
        // 你可以在这里执行你的操作，例如套利、再融资等。
        // 对于这个简单示例，我们什么都不做，直接准备归还。

        uint256 amountToRepay = _amount + _fee;

        //1.授权LendingPool从本合约提取amountToRepay
        console.log("Amount to repay:", amountToRepay);
    console.log("Approving LendingPool to spend:", amountToRepay, "of asset:", _asset);

 
        IERC20 token = IERC20(_asset);
        require(token.approve(lendingPool, 0), "Approve reset failed");
        require(token.approve(lendingPool, amountToRepay), "Approve failed");

    // 检查 approve 是否成功 (虽然 safeApprove 失败会 revert，但可以加个 balanceOf 检查授权后的 allowance)
    uint256 allowance = IERC20(_asset).allowance(address(this), lendingPool);
    console.log("Allowance for LendingPool after approve:", allowance);
    require(allowance >= amountToRepay, "Approval failed or insufficient");

        
        emit LoanReceivedAndRepaid(_initiator, _asset, _amount, _fee);
        
        return true; // 返回 true 表示操作成功，LendingPool 将会尝试取回资金
    
    }
    // 可选：允许合约所有者提取意外发送到此合约的 ERC20 代币
    function withdrawTokens(address _tokenAddress, address _to, uint256 _amount) external onlyOwner {
        IERC20(_tokenAddress).safeTransfer(_to, _amount);
    }

    // 可选：允许合约接收 ETH (如果需要的话)
    receive() external payable {}
}