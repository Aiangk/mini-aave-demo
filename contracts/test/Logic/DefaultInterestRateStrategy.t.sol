// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
//专门用来测试DefaultInterestRateStrategy合约的测试文件

import {Test} from 'forge-std/Test.sol';
import {DefaultInterestRateStrategy} from '../../src/Logic/DefaultInterestRateStrategy.sol';
import {IInterestRateStrategy, RateCalculationParams} from '../../src/Interfaces/IInterestRateStrategy.sol';

contract DefaultInterestRateStrategyTest is Test {
  DefaultInterestRateStrategy internal rateStrategy;

  // 定义利率模型参数（年华，RAY单位）
  uint256 constant BASE_BORROW_RATE = 0; // 基础借款利率 0% APR
  uint256 constant SLOPE_1 = 0.04 * 1e27; // 4% APR
  uint256 constant SLOPE_2 = 0.75 * 1e27; // 75% APR
  uint256 constant OPTIMAL_UTILIZATION = 0.8 * 1e27; // 80%
  uint256 constant RAY = 1e27;
  uint256 constant PERCENTAGE_FACTOR = 10000; // For reserve factor(10% = 1000)

  function setUp() public {
    rateStrategy = new DefaultInterestRateStrategy(
      BASE_BORROW_RATE,
      SLOPE_1,
      SLOPE_2,
      OPTIMAL_UTILIZATION
    );
  }

  function test_IRS_calculateInterestRates_ZeroUtilization() public view {
    // 测试当利用率为0时，计算出的利率
    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: 1000 * 1e18, // 1000 存款
      totalBorrows: 0, // 0 借款
      totalReserves: 0, // 0 储备
      availableLiquidity: 1000 * 1e18, // 1000 可用流动性
      reserveFactorBps: 1000 // 10% 储备因子
    });

    (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate) = rateStrategy
      .calculateInterestRates(params);
    // totalDeposits = availableLiquidity,说明一分钱都没有借出去。0%utilization
    // 所以BorrowRate = baseBorrowRate = 0
    // 所以LiquidityRate = 0

    assertEq(
      annualVariableBorrowRate,
      BASE_BORROW_RATE,
      'Annual Variable Borrow Rate at 0% U mismatch'
    );
    assertEq(annualLiquidityRate, 0, 'Annual Liquidity Rate at 0% U mismatch');
  }

  function test_IRS_calculateInterestRates_BelowOptimalUtilization() public view {
    // 测试当利用率低于80%时，计算出的利率
    // 举例：50% utilization
    uint256 totalDeposits = 1000 * 1e18;
    uint256 totalBorrows = 500 * 1e18;
    uint256 reserveFactorBps = 1000;

    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: totalDeposits,
      totalBorrows: totalBorrows,
      totalReserves: 0,
      availableLiquidity: totalDeposits - totalBorrows,
      reserveFactorBps: reserveFactorBps
    });

    (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate) = rateStrategy
      .calculateInterestRates(params);

    uint256 utilizationRate_RAY = (totalBorrows * RAY) / totalDeposits;
    uint256 expectedVariableBorrowRate = BASE_BORROW_RATE + (SLOPE_1 * utilizationRate_RAY) / RAY;
    assertEq(
      annualVariableBorrowRate,
      expectedVariableBorrowRate,
      'Annual Variable Borrow Rate at 50% U mismatch'
    );

    // 计算LiquidityRate
    uint256 grossLiquidityIncomeRate = (annualVariableBorrowRate * utilizationRate_RAY) / RAY;
    uint256 expectedAnnualLiquidityRate = (grossLiquidityIncomeRate *
      (PERCENTAGE_FACTOR - reserveFactorBps)) / PERCENTAGE_FACTOR;
    assertEq(
      annualLiquidityRate,
      expectedAnnualLiquidityRate,
      'Annual Liquidity Rate at 50% U mismatch'
    );
  }

  function test_IRS_calculateInterestRates_AtOptimalUtilization() public view {
    uint256 totalDeposits = 1000 * 1e18;
    uint256 totalBorrows = 800 * 1e18; // 80% Utilization (OPTIMAL_UTILIZATION)
    uint256 reserveFactorBps = 2000; // 20%

    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: totalDeposits,
      totalBorrows: totalBorrows,
      totalReserves: 0,
      availableLiquidity: totalDeposits - totalBorrows,
      reserveFactorBps: reserveFactorBps
    });
    (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate) = rateStrategy
      .calculateInterestRates(params);

    // Expected annual variable borrow rate at Optimal U (80%):
    // Base (0) + OptimalU (0.8 RAY) * Slope1 (0.04 RAY) / RAY = 0.8 * 0.04 RAY = 0.032 RAY (3.2% APR)
    uint256 expectedAnnualVariableBorrowRate = BASE_BORROW_RATE +
      (OPTIMAL_UTILIZATION * SLOPE_1) /
      RAY;
    assertEq(
      annualVariableBorrowRate,
      expectedAnnualVariableBorrowRate,
      'Annual Variable Borrow Rate at Optimal U mismatch'
    );

    uint256 utilizationRate_RAY = (totalBorrows * RAY) / totalDeposits;
    uint256 grossLiquidityIncomeRate = (annualVariableBorrowRate * utilizationRate_RAY) / RAY;
    uint256 expectedAnnualLiquidityRate = (grossLiquidityIncomeRate *
      (PERCENTAGE_FACTOR - reserveFactorBps)) / PERCENTAGE_FACTOR;
    assertEq(
      annualLiquidityRate,
      expectedAnnualLiquidityRate,
      'Annual Liquidity Rate at Optimal U mismatch'
    );
  }

  function test_IRS_calculateInterestRates_AboveOptimalUtilization() public view {
    uint256 totalDeposits = 1000 * 1e18;
    uint256 totalBorrows = 900 * 1e18; // 90% Utilization
    uint256 reserveFactorBps = 0; // 0% reserve factor for simplicity here

    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: totalDeposits,
      totalBorrows: totalBorrows,
      totalReserves: 0,
      availableLiquidity: totalDeposits - totalBorrows,
      reserveFactorBps: reserveFactorBps
    });
    (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate) = rateStrategy
      .calculateInterestRates(params);

    // Expected annual variable borrow rate at 90% U:
    // RateAtOptimalU = Base (0) + OptimalU (0.8 RAY) * Slope1 (0.04 RAY) / RAY = 0.032 RAY
    // AdditionalRate = (Utilization (0.9 RAY) - OptimalU (0.8 RAY)) * Slope2 (0.75 RAY) / RAY
    //                = (0.1 RAY) * Slope2 (0.75 RAY) / RAY = 0.1 * 0.75 RAY = 0.075 RAY
    // Total = 0.032 RAY + 0.075 RAY = 0.107 RAY (10.7% APR)
    uint256 rateAtOptimalU = BASE_BORROW_RATE + (OPTIMAL_UTILIZATION * SLOPE_1) / RAY;
    uint256 utilizationAboveOptimal_RAY = ((totalBorrows * RAY) / totalDeposits) -
      OPTIMAL_UTILIZATION;
    uint256 expectedAnnualVariableBorrowRate = rateAtOptimalU +
      (utilizationAboveOptimal_RAY * SLOPE_2) /
      RAY;
    assertEq(
      annualVariableBorrowRate,
      expectedAnnualVariableBorrowRate,
      'Annual Variable Borrow Rate at 90% U mismatch'
    );

    uint256 utilizationRate_RAY = (totalBorrows * RAY) / totalDeposits;
    uint256 grossLiquidityIncomeRate = (annualVariableBorrowRate * utilizationRate_RAY) / RAY;
    uint256 expectedAnnualLiquidityRate = (grossLiquidityIncomeRate *
      (PERCENTAGE_FACTOR - reserveFactorBps)) / PERCENTAGE_FACTOR; // RF is 0 here
    assertEq(
      annualLiquidityRate,
      expectedAnnualLiquidityRate,
      'Annual Liquidity Rate at 90% U mismatch'
    );
  }

  function test_IRS_calculateInterestRates_NoDeposits() public view {
    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: 0,
      totalBorrows: 0,
      totalReserves: 0,
      availableLiquidity: 0,
      reserveFactorBps: 1000
    });

    (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate) = rateStrategy
      .calculateInterestRates(params);
    assertEq(annualLiquidityRate, 0, 'Liquidity rate should be 0 if no deposits');
    assertEq(
      annualVariableBorrowRate,
      BASE_BORROW_RATE,
      'Borrow rate should be base if no deposits'
    );
  }
}
