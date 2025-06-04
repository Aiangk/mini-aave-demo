//利息策略接口
//精确计算：引入 Aave 中常用的 RAY 数学 (10^27 精度) 来进行利息的精确计算和指数更新。
//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


struct RateCalculationParams {
    uint256 totalDeposits;
    uint256 totalBorrows;
    uint256 totalReserves;  //reserves储备金
    uint256 availableLiquidity; // totalDeposits - totalBorrows
    uint256 reserveFactorBps; //  新增: 准备金率，例如 1000 代表 10.00% (万分之1000)
}
interface IInterestRateStrategy {
    function calculateInterestRates(
        RateCalculationParams memory params
    ) external view returns (
        uint256 liquidityRate, 
        uint256 variableBorrowRate); //variableBorrowRate 可变借贷利率
}
