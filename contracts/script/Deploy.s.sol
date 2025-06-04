// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from 'forge-std/Script.sol';
import {console} from 'forge-std/console.sol';

import {LendingPool} from '../src/Core/LendingPool.sol';
import {Configurator} from '../src/Core/Configurator.sol';
import {PriceOracle} from '../src/Oracles/PriceOracle.sol';
import {DefaultInterestRateStrategy} from '../src/Logic/DefaultInterestRateStrategy.sol';
import {MockERC20} from '../src/Mocks/MockERC20.sol';
import {ILendingPool} from '../src/Interfaces/ILendingPool.sol';
import {AToken} from '../src/Tokens/AToken.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {FlashLoanReceiverExample} from '../src/Example/FlashLoanReceiverExample.sol';

contract Deploy is Script {
  // MockERC20 代币参数
  uint8 constant DAI_DECIMALS = 18;
  uint8 constant USDC_DECIMALS = 6;
  uint256 constant INITIAL_TOKEN_SUPPLY_FACTOR = 1_000_000;

  // 利率模型参数 (年化, RAY 单位)
  uint256 constant RAY = 10 ** 27;
  uint256 constant DEFAULT_BASE_BORROW_RATE = (2 * RAY) / 100; // 2% 年化基础借款利率
  uint256 constant DEFAULT_SLOPE_1 = (4 * RAY) / 100; // 4% 年化利率斜率1
  uint256 constant DEFAULT_SLOPE_2 = (75 * RAY) / 100; // 75% 年化利率斜率2
  uint256 constant DEFAULT_OPTIMAL_UTILIZATION = (80 * RAY) / 100; // 80% 最佳利用率

  // 资产配置参数 (基于 PERCENTAGE_FACTOR = 10000)
  uint256 constant DAI_LTV = 7500; // 75%
  uint256 constant DAI_LIQ_THRESHOLD = 8000; // 80%
  uint256 constant DAI_RESERVE_FACTOR = 1000; // 10%
  uint256 constant DAI_LIQ_BONUS = 500; // 5%

  uint256 constant USDC_LTV = 7500; // 75%
  uint256 constant USDC_LIQ_THRESHOLD = 8000; // 80%
  uint256 constant USDC_RESERVE_FACTOR = 1000; // 10%
  uint256 constant USDC_LIQ_BONUS = 500; // 5%

  // 使用 Anvil 第一个账户的私钥
  uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address deployerAddress = vm.addr(deployerPrivateKey);

  // 使用 Anvil 第二个账户的正确私钥
  uint256 bobPrivateKey = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
  address bob = vm.addr(bobPrivateKey); // 确保 bob 地址是由 bobPrivateKey 推导出来的 // <--- 确保是这一行，而不是硬编码


  // 价格预言机价格小数位数
  uint8 constant ORACLE_PRICE_DECIMALS = 8;

  function run()
    external
    returns (
      LendingPool lendingPool,
      Configurator configurator,
      PriceOracle priceOracle,
      MockERC20 dai,
      MockERC20 usdc
    )
  {
    console.log('>>>> EXECUTING SCRIPT VERSION XYZ_UNIQUE_MARKER <<<<');

   
    // 确保账户有足够的 ETH
    vm.deal(deployerAddress, 3000000 ether);
    vm.deal(bob, 3000000 ether);

    console.log('Using Anvil Default Account #0 as Deployer:', deployerAddress);
    console.log('Initial balance for deployer:', deployerAddress.balance);
    console.log('Setting up Bob (Anvil Account #1) at address:', bob);
    console.log('Initial balance for Bob:', bob.balance);

    // --- 第一阶段: 部署者部署合约和初始设置 ---
    console.log('\n--- Stage 1: Deploy contracts and initial setup ---');
    vm.startBroadcast(deployerPrivateKey);

    // 1. 部署基础合约
    priceOracle = new PriceOracle();
    console.log('PriceOracle deployed at:', address(priceOracle));

    dai = new MockERC20(
      'Mock DAI',
      'mDAI',
      DAI_DECIMALS,
      INITIAL_TOKEN_SUPPLY_FACTOR * (10 ** DAI_DECIMALS)
    );
    console.log('MockDAI deployed at:', address(dai));

    usdc = new MockERC20(
      'Mock USDC',
      'mUSDC',
      USDC_DECIMALS,
      INITIAL_TOKEN_SUPPLY_FACTOR * (10 ** USDC_DECIMALS)
    );
    console.log('MockUSDC deployed at:', address(usdc));

    // 2. 部署利率策略
    DefaultInterestRateStrategy daiRateStrategy = new DefaultInterestRateStrategy(
      DEFAULT_BASE_BORROW_RATE,
      DEFAULT_SLOPE_1,
      DEFAULT_SLOPE_2,
      DEFAULT_OPTIMAL_UTILIZATION
    );
    console.log('DAIRateStrategy deployed at:', address(daiRateStrategy));

    DefaultInterestRateStrategy usdcRateStrategy = new DefaultInterestRateStrategy(
      DEFAULT_BASE_BORROW_RATE,
      DEFAULT_SLOPE_1,
      DEFAULT_SLOPE_2,
      DEFAULT_OPTIMAL_UTILIZATION
    );
    console.log('USDCRateStrategy deployed at:', address(usdcRateStrategy));

    // 3. 部署和配置 Configurator 和 LendingPool
    configurator = new Configurator(address(0));
    console.log('Configurator deployed at:', address(configurator));

    lendingPool = new LendingPool(address(configurator), address(priceOracle));
    console.log('LendingPool deployed at:', address(lendingPool));

    configurator.setLendingPool(address(lendingPool));
    console.log("Configurator's LendingPool address set to:", address(lendingPool));

    // 4. 配置资产
    configurator.addAsset(
      address(dai),
      DAI_LTV,
      DAI_LIQ_THRESHOLD,
      address(daiRateStrategy),
      DAI_RESERVE_FACTOR,
      DAI_LIQ_BONUS
    );
    console.log('DAI configured in LendingPool.');

    configurator.addAsset(
      address(usdc),
      USDC_LTV,
      USDC_LIQ_THRESHOLD,
      address(usdcRateStrategy),
      USDC_RESERVE_FACTOR,
      USDC_LIQ_BONUS
    );
    console.log('USDC configured in LendingPool.');

    // 闪电贷例子
    address lendingPoolAddressForReceiver = address(lendingPool); // 获取已部署的 LendingPool 地址
    FlashLoanReceiverExample flashLoanReceiver = new FlashLoanReceiverExample(lendingPoolAddressForReceiver);
    console.log("FlashLoanReceiverExample deployed at:", address(flashLoanReceiver));

    address flashLoanReceiverAddress = address(flashLoanReceiver);
    uint256 feeReserveDAI = 1 * (10**DAI_DECIMALS); // 预存 1 mDAI 作为手续费储备
    uint256 feeReserveUSDC = 1 * (10**USDC_DECIMALS); // 预存 1 mUSDC

    dai.transfer(flashLoanReceiverAddress, feeReserveDAI);
    usdc.transfer(flashLoanReceiverAddress, feeReserveUSDC);
    console.log("Transferred initial fee reserves to FlashLoanReceiverExample.");


    // 5. 设置初始价格
    priceOracle.setAssetPrice(address(dai), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    priceOracle.setAssetPrice(address(usdc), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    console.log('Initial prices set for DAI and USDC in PriceOracle.');

    // 6. 部署者存入初始流动性
    uint256 initialDaiLiquidity = 100_000 * (10 ** DAI_DECIMALS);
    uint256 initialUsdcLiquidity = 100_000 * (10 ** USDC_DECIMALS);

    dai.approve(address(lendingPool), initialDaiLiquidity);
    lendingPool.deposit(address(dai), initialDaiLiquidity);
    console.log('Deposited initial DAI liquidity by deployer.');

    usdc.approve(address(lendingPool), initialUsdcLiquidity);
    lendingPool.deposit(address(usdc), initialUsdcLiquidity);
    console.log('Deposited initial USDC liquidity by deployer.');

    // 7. 给 Bob 转一些代币
    uint256 amountToSendToBobDAI = 2000 * (10 ** DAI_DECIMALS);
    uint256 amountToSendToBobUSDC = 1000 * (10 ** USDC_DECIMALS);

    dai.transfer(bob, amountToSendToBobDAI);
    usdc.transfer(bob, amountToSendToBobUSDC);
    console.log('Transferred mDAI and mUSDC to Bob.');

    vm.stopBroadcast();

    // --- 第二阶段: Bob 的操作 ---
    
    console.log('\n--- Stage 2: Bob deposits and borrows ---');

    // 获取DAI的AToken地址
    ILendingPool.AssetDataReturn memory daiAssetData = lendingPool.getAssetData(address(dai));
    address daiATokenAddress = daiAssetData.aTokenAddress;
    console.log('DAI aToken address:', daiATokenAddress);

    uint256 bobDaiDepositAmount = 1000 * 10**18; // Bob 存入 1000 mDAI
    uint256 bobUsdcBorrowAmount = 750 * 10**6;   // Bob 借出 750 mUSDC (USDC 6位小数)
    
    console.log("Address derived from bobPrivateKey by vm.addr just before broadcast:", vm.addr(bobPrivateKey));
    vm.startBroadcast(bobPrivateKey); // <--- 使用 bobPrivateKey

    console.log("Bob approving LendingPool for mDAI...");
    dai.approve(address(lendingPool), bobDaiDepositAmount);
    console.log("Bob approved LendingPool for mDAI.");

    console.log("Bob depositing %s mDAI as collateral...", bobDaiDepositAmount / (10**18));
    lendingPool.deposit(address(dai), bobDaiDepositAmount);
    console.log("Bob deposited mDAI as collateral."); // 日志可以更简洁

    console.log("Bob borrowing %s mUSDC...", bobUsdcBorrowAmount / (10**6));
    lendingPool.borrow(address(usdc), bobUsdcBorrowAmount); // <--- 确保此行已取消注释并执行
    console.log("Bob borrowed mUSDC.");

    vm.stopBroadcast();

    
    // --- 第三阶段: 部署者降低 DAI 价格 ---
    
    console.log('\n--- Stage 3: Lower DAI price ---');
    vm.startBroadcast(deployerPrivateKey);

    // 将 DAI 价格下调至 0.60 美元
    uint256 newDaiPrice = 60 * (10 ** (ORACLE_PRICE_DECIMALS - 2));
    priceOracle.setAssetPrice(address(dai), newDaiPrice);
    console.log('Simulated DAI price drop to $0.60');

    vm.stopBroadcast();
    
    // 最终健康因子
    uint256 bobHealthFactorAfter = lendingPool.calculateHealthFactor(bob);
    console.log("Bob's Health Factor AFTER price drop:", bobHealthFactorAfter);

    // 最终状态验证
    console.log('\n--- Final state verification ---');
    console.log("Bob's DAI balance:", dai.balanceOf(bob));
    console.log("Bob's USDC balance:", usdc.balanceOf(bob));
    console.log("Bob's DAI collateral:", lendingPool.getEffectiveUserDeposit(address(dai), bob));
    console.log(
      "Bob's USDC borrow:",
      lendingPool.getEffectiveUserBorrowBalance(address(usdc), bob)
    );

    console.log('Script finished all intended operations.');

    return (lendingPool, configurator, priceOracle, dai, usdc);
  }
}
