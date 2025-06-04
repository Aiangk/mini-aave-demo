//实现一个基于资金利用率的简单线性利率模型。参数（如基础利率、斜率、最优利用率）应可配置。
//想象一个图表，X轴是资金利用率 (U)，Y轴是借款年化利率 (APR)。
// 从 U=0% 到 U= optimalUtilizationRate (比如 80%)，利率从一个基础利率 (baseVariableBorrowRate) 开始，按照 variableRateSlope1 的斜率线性上升。
// 当 U 超过 optimalUtilizationRate (比如从 80% 到 100%)，利率会从在 optimalUtilizationRate 点达到的利率值开始，按照一个更陡峭的斜率 variableRateSlope2 急速上升。
//这种设计有助于：
//低利用率时：保持较低的借款成本，吸引借款。
// 高利用率时：通过提高利率来抑制过度借款，并吸引新的存款，从而降低利用率，保证池子有足够的流动性供用户取款。
//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IInterestRateStrategy, RateCalculationParams} from "../Interfaces/IInterestRateStrategy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DefaultInterestRateStrategy is IInterestRateStrategy, Ownable {
    // --- Constants ---
    uint256 public constant RAY = 1e27;
    uint256 public constant PERCENTAGE_FACTOR = 10000;

    // 简单线性模型的示例参数（年利率，由 RAY 缩放）
    // 这些参数应针对每个资产进行设置，但对于默认策略，我们可以设置一组。
    // 在实际的 Aave 中，这些参数由管理员根据每个储备库进行配置
    // 年化利率 (APR - Annual Percentage Rate)：通常我们讨论利率时指的是年利率。但在智能合约中，利息是按秒或按区块累积的，所以需要将年利率转换为对应的秒利率或区块利率。

    uint256 public baseVariableBorrowRate; //e.g., 0% APR = 0 RAY
    uint256 public variableRateSlope1; //RateSlope 斜率 7% APR = 0.07 * RAY
    uint256 public variableRateSlope2; //   e.g. 300% APR = 3 * RAY
    uint256 public optimalUtilizationRate; //最佳 利用 率  e.g. 80% APR = 0.8 * RAY

    event RatesUpdated(
        uint256 baseVariableBorrowRate,
        uint256 variableRateSlope1,
        uint256 variableRateSlope2,
        uint256 optimalUtilizationRate
    );

    constructor(
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2,
        uint256 _optimalUtilizationRate
    ) Ownable(msg.sender) {
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1 = _variableRateSlope1;
        variableRateSlope2 = _variableRateSlope2;
        optimalUtilizationRate = _optimalUtilizationRate;
    }

    function calculateInterestRates(
        RateCalculationParams memory params
    )
        external
        view
        override
        returns (uint256 annualLiquidityRate, uint256 annualVariableBorrowRate)
    {
        uint256 utilizationRate_RAY;

        // (1) 处理特殊情况：池中没有存款
        if (params.totalDeposits == 0) {
            return (0, baseVariableBorrowRate);
            // 注意：这里的 baseVariableBorrowRate 是年化利率，需要转换为每秒利率。
        }

        // (2) 计算资金利用率 (U)
        // U = 总借款 / 总存款
        // 为了保持精度，并使用 RAY 单位 (1e27)，我们先将 totalBorrows 乘以 RAY。
        utilizationRate_RAY =
            (params.totalBorrows * RAY) /
            params.totalDeposits;

        // (3) 根据利用率分段计算年化浮动借款利率 (Annual Variable Borrow Rate)
        // 这里的 baseVariableBorrowRate, variableRateSlope1, variableRateSlope2, optimalUtilizationRate
        // 都是合约的公开状态变量，它们是以年化利率的 RAY 单位存储的。
        if (utilizationRate_RAY < optimalUtilizationRate) {
            // 当 U < 最优利用率时，利率 = 基础利率 + U * 斜率1
            annualVariableBorrowRate =
                baseVariableBorrowRate +
                ((utilizationRate_RAY * variableRateSlope1) / RAY);
            // 为啥最后除以RAY，因为两个乘数都是RAY单位，乘积会变成 RAY^2 单位，所以除以 RAY 变回 RAY 单位。
        } else {
            // 当 U >= 最优利用率时，利率 = 基础利率 + 最优利用率部分产生的利率 + 超出部分产生的利率
            annualVariableBorrowRate =
                baseVariableBorrowRate +
                (optimalUtilizationRate * variableRateSlope1) /
                RAY +
                ((utilizationRate_RAY - optimalUtilizationRate) *
                    variableRateSlope2) /
                RAY;
        }

        //计算提供给存款人的净年化流动性利率
        uint256 grossPotentialLiquidityIncome_RAY = (annualVariableBorrowRate *
            utilizationRate_RAY) / RAY;

        annualLiquidityRate =
            (grossPotentialLiquidityIncome_RAY *
                (PERCENTAGE_FACTOR - params.reserveFactorBps)) /
            PERCENTAGE_FACTOR;
    }

    // --- Admin functions to update rates ---
    function setRates(
        uint256 _baseVariableBorrowRate,
        uint256 _variableRateSlope1,
        uint256 _variableRateSlope2,
        uint256 _optimalUtilizationRate
    ) external onlyOwner {
        baseVariableBorrowRate = _baseVariableBorrowRate;
        variableRateSlope1 = _variableRateSlope1;
        variableRateSlope2 = _variableRateSlope2;
        optimalUtilizationRate = _optimalUtilizationRate;
    }
}
