// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from 'forge-std/Test.sol';
import {console2} from 'forge-std/console2.sol';
import {Vm} from 'forge-std/Vm.sol';
import {LendingPool} from '../src/Core/LendingPool.sol';
import {Configurator} from '../src/Core/Configurator.sol';
import {MockERC20} from '../src/Mocks/MockERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {PriceOracle} from '../src/Oracles/PriceOracle.sol';
import {DefaultInterestRateStrategy} from '../src/Logic/DefaultInterestRateStrategy.sol';
import {ILendingPool} from '../src/Interfaces/ILendingPool.sol';
import {MockFlashLoanReceiver} from './Mocks/MockFlashLoanReceiver.sol';
import {IFlashLoanReceiver} from '../src/Interfaces/IFlashLoanReceiver.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

contract LendingPoolTest is Test {
  event Deposited(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event AssetConfigured(
    address indexed asset,
    bool isSupported,
    uint8 decimals, //资产自己的decimals
    uint256 ltv,
    uint256 liquidationThreshold,
    address interestRateStrategy,
    uint256 reserveFactor,
    uint256 liquidationBonus
  );

  event LiquidationCall(
    address indexed collateralAsset, //被清算的抵押品资产
    address indexed debtAsset,
    address indexed user,
    uint256 debtToCover,
    uint256 liquidatedCollateralAmount,
    address liquidator,
    bool receiveUnderlyingCollateral,
    uint256 timestamp
  );

  event Withdrawn(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event Borrowed(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event Repaid(
    address indexed asset,
    address indexed userToRepayFor,
    address indexed repayer,
    uint256 amount,
    uint256 scaledAmount,
    uint256 timestamp
  );

  event ReserveFactorUpdated(address indexed asset, uint256 newReserveFactor);
  event InterestRateStrategyUpdated(address indexed asset, address newStrategyAddress);

  event ReservesCollected(
    address indexed asset,
    address indexed reserveCollector,
    uint256 amountCollected
  );

  event FlashLoan(
    address indexed targetReceiver, // 接收闪电贷的合约地址
    address indexed initiator, // 发起闪电贷的原始调用者
    address indexed asset, // 借出的资产
    uint256 amount, // 借出的数量
    uint256 fee, // 支付的手续费
    uint256 timestamp
  );

  LendingPool internal lendingPool;
  ILendingPool internal IlendingPool;

  Configurator internal configurator;
  PriceOracle internal priceOracle;
  MockERC20 internal dai;
  MockERC20 internal usdc;
  MockERC20 internal eth;

  DefaultInterestRateStrategy internal daiRateStrategy;
  DefaultInterestRateStrategy internal usdcRateStrategy;

  MockFlashLoanReceiver internal flashLoanReceiver;

  address internal admin = address(this); // Test contract itself is admin for Ownable
  address internal user1 = makeAddr('user1');
  address internal user2 = makeAddr('user2');

  uint256 constant FLASHLOAN_TEST_AMOUNT = 100 * (10 ** USDC_DECIMALS);
  uint8 constant DAI_DECIMALS = 18;
  uint8 constant USDC_DECIMALS = 6;
  uint8 constant ORACLE_PRICE_DECIMALS = 8; // Matches PriceOracle.PRICE_DECIMALS

  uint256 constant INITIAL_DAI_SUPPLY = 1_000_000 * (10 ** DAI_DECIMALS);
  uint256 constant INITIAL_USDC_SUPPLY = 1_000_000 * (10 ** USDC_DECIMALS);

  uint256 constant DEFAULT_BASE_BORROW_RATE = 0;
  uint256 constant DEFAULT_SLOPE_1 = 0.04 * 1e27;
  uint256 constant DEFAULT_SLOPE_2 = 0.75 * 1e27;
  uint256 constant DEFAULT_OPTIMAL_UTILIZATION = 0.8 * 1e27;

  uint256 constant PERCENTAGE_FACTOR = 1e4;
  uint256 constant HEALTH_FACTOR_PRECISION = 10 ** 18; // 健康因子精度 (例如 1.0 代表 1e18)
  uint256 constant MINIMUM_HEALTH_FACTOR = 1 * HEALTH_FACTOR_PRECISION; // 最小健康因子

  function setUp() public {
    //1.部署PriceOracle
    priceOracle = new PriceOracle(); //owner is admin (address(this))

    //2.部署Configurator
    configurator = new Configurator(address(0));

    // 3. Deploy final LendingPool with correct Configurator and PriceOracle addresses
    lendingPool = new LendingPool(address(configurator), address(priceOracle));
    IlendingPool = LendingPool(address(lendingPool));
    // 4. Update Configurator with the final LendingPool address
    vm.prank(admin); // Configurator is Ownable by admin
    configurator.setLendingPool(address(lendingPool));

    // 5. Deploy Mock Tokens
    dai = new MockERC20('Dai Stablecoin', 'DAI', DAI_DECIMALS, INITIAL_DAI_SUPPLY);
    usdc = new MockERC20('USD Coin', 'USDC', USDC_DECIMALS, INITIAL_USDC_SUPPLY);
    eth = new MockERC20('Ethereum', 'ETH', 18, 1000000 * 1e18);

    // 6. Transfer tokens to users
    dai.transfer(user1, 1000 * (10 ** DAI_DECIMALS));
    usdc.transfer(user1, 1000 * (10 ** USDC_DECIMALS));
    dai.transfer(user2, 1000 * (10 ** DAI_DECIMALS));
    usdc.transfer(user2, 1000 * (10 ** USDC_DECIMALS));

    // 7. Deploy DefaultInterestRateStrategy for DAI and USDC
    daiRateStrategy = new DefaultInterestRateStrategy(
      DEFAULT_BASE_BORROW_RATE,
      DEFAULT_SLOPE_1,
      DEFAULT_SLOPE_2,
      DEFAULT_OPTIMAL_UTILIZATION
    );
    usdcRateStrategy = new DefaultInterestRateStrategy(
      DEFAULT_BASE_BORROW_RATE,
      DEFAULT_SLOPE_1,
      DEFAULT_SLOPE_2,
      DEFAULT_OPTIMAL_UTILIZATION
    );

    // 8. Admin configures assets in LendingPool
    vm.startPrank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    // 9. Set prices
    priceOracle.setAssetPrice(address(dai), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    priceOracle.setAssetPrice(address(usdc), 1 * (10 ** ORACLE_PRICE_DECIMALS));

    // 10. Add initial liquidity to the pool
    dai.mint(admin, 100000 * (10 ** DAI_DECIMALS)); // 铸造足够的代币
    usdc.mint(admin, 100000 * (10 ** USDC_DECIMALS));
    dai.approve(address(lendingPool), 100000 * (10 ** DAI_DECIMALS));
    usdc.approve(address(lendingPool), 100000 * (10 ** USDC_DECIMALS));
    lendingPool.deposit(address(dai), 10000 * (10 ** DAI_DECIMALS));
    lendingPool.deposit(address(usdc), 10000 * (10 ** USDC_DECIMALS));
    vm.stopPrank();
  }

  // --- Price Tests ---
  function test_P2_AdminCanConfigureAsset() public {
    vm.startPrank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    vm.stopPrank();

    ILendingPool.AssetDataReturn memory assetData = lendingPool.getAssetData(address(dai));
    assertTrue(assetData.isSupported);
    assertEq(assetData.decimals, DAI_DECIMALS);
    assertEq(assetData.ltv, 7500);
    assertEq(assetData.liquidationThreshold, 8000);
  }

  function test_P2_GetUserTotalCollateralUSD_SingleAsset() public {
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS);
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS); // $1 per DAI

    //1. Admin configures DAI
    vm.startPrank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);

    //2. Admin sets DAI price in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    vm.stopPrank();

    //3. User1 deposits DAI
    vm.startPrank(user1);
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    vm.stopPrank();

    //4. Assert total collateral value
    uint256 expectedCollateralUSD = (daiDepositAmount * daiPrice) / (10 ** DAI_DECIMALS);
    assertEq(
      lendingPool.getUserTotalCollateralUSD(user1),
      expectedCollateralUSD,
      'User1 total collateral value mismatch'
    );
  }

  function test_P2_GetUserTotalCollateralUSD_MultipleAssets() public {
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS);
    uint256 usdcDepositAmount = 100 * (10 ** USDC_DECIMALS);
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS); // $1 per DAI
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS); // $1 per USDC

    //1. Admin configures DAI and USDC
    vm.startPrank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);
    vm.stopPrank();

    //2. Admin sets prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);

    //3. User1 deposits DAI and USDC
    vm.startPrank(user1);
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    usdc.approve(address(lendingPool), usdcDepositAmount);
    lendingPool.deposit(address(usdc), usdcDepositAmount);
    vm.stopPrank();

    //4. Assert total collateral value
    uint256 expectedCollateralUSD = (daiDepositAmount * daiPrice) /
      (10 ** DAI_DECIMALS) +
      (usdcDepositAmount * usdcPrice) /
      (10 ** USDC_DECIMALS);
    assertEq(
      lendingPool.getUserTotalCollateralUSD(user1),
      expectedCollateralUSD,
      'User1 total collateral value mismatch'
    );
  }

  // --- Configurator Tests ---

  function test_Fail_NonAdminCannotAddAsset() public {
    vm.prank(user1);
    vm.expectRevert('Ownable: caller is not the owner');
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
  }

  function test_AdminCanRemoveAsset() public {
    vm.prank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 0, 0);
    configurator.removeAsset(address(dai));
    ILendingPool.AssetDataReturn memory assetData = lendingPool.getAssetData(address(dai));
    assertFalse(assetData.isSupported, 'DAI should not be supported after removal');
  }

  // --- Deposit Tests ---

  function test_UserCanDepositSupportedAsset() public {
    uint256 depositAmount = 100 * 1e18;

    //Admin configures DAI
    vm.prank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);

    //User1 approves LendingPool and deposits DAI
    vm.startPrank(user1);
    dai.approve(address(lendingPool), depositAmount);
    uint256 scaledAmount = (depositAmount * lendingPool.RAY()) / (10 ** DAI_DECIMALS);

    uint256 currentBlockTimestamp = block.timestamp; // Capture current block timestamp
    vm.expectEmit(true, true, false, false, address(lendingPool)); // checkTopic3=false, checkData=true
    emit Deposited(address(dai), user1, depositAmount, scaledAmount, currentBlockTimestamp);
    lendingPool.deposit(address(dai), depositAmount); // Should use the same block.timestamp internally
    vm.stopPrank();

    assertEq(
      lendingPool.getEffectiveUserDeposit(address(dai), user1),
      depositAmount,
      'User1 DAI deposit mismatch'
    );
  }

  function test_Fail_UserCannotDepositUnsupportedAsset() public {
    uint256 depositAmount = 100 * 1e18;
    //ETH is not supported

    vm.startPrank(user1);
    dai.approve(address(lendingPool), depositAmount);
    vm.expectRevert('LendingPool: Asset not supported');
    lendingPool.deposit(address(eth), depositAmount);
    vm.stopPrank();
  }

  function test_Fail_UserCannotDepositZeroAmount() public {
    vm.prank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);

    vm.startPrank(user1);
    dai.approve(address(lendingPool), 0);
    vm.expectRevert('LendingPool: Amount must be > 0');
    lendingPool.deposit(address(dai), 0);
    vm.stopPrank();
  }

  // --- Withdraw Tests ---

  function test_UserCanWithdrawDeposit() public {
    uint256 depositAmount = 100 * 1e18;
    uint256 withdrawAmount = 50 * 1e18;

    //Setup: Admin adds DAI, User1 deposits DAI
    vm.prank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);

    vm.startPrank(user1);
    dai.approve(address(lendingPool), depositAmount);
    lendingPool.deposit(address(dai), depositAmount);
    vm.stopPrank();

    uint256 scaledAmount = (withdrawAmount * lendingPool.RAY()) / (10 ** DAI_DECIMALS);
    //Action: User1 withdraws DAI
    vm.startPrank(user1);
    vm.expectEmit(true, true, false, false, address(lendingPool));
    emit Withdrawn(address(dai), user1, withdrawAmount, scaledAmount, uint256(block.timestamp));
    lendingPool.withdraw(address(dai), withdrawAmount);
    vm.stopPrank();

    assertEq(
      lendingPool.getEffectiveUserDeposit(address(dai), user1),
      depositAmount - withdrawAmount,
      'User1 DAI deposit after withdrawal mismatch'
    );
  }

  function test_UserCannotWithdrawMoreThanDeposited() public {
    uint256 depositAmount = 100 * 1e18;
    uint256 withdrawAmount = 150 * 1e18;

    vm.prank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    vm.startPrank(user1);
    dai.approve(address(lendingPool), depositAmount);
    lendingPool.deposit(address(dai), depositAmount);

    vm.expectRevert('LendingPool: Insufficient available balance for withdrawal');
    lendingPool.withdraw(address(dai), withdrawAmount);
    vm.stopPrank();
  }

  // --- Borrow Tests ---
  function test_P3_UserCannotBorrow_InsufficientCollateral() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 usdcDepositAmount = 10 * (10 ** USDC_DECIMALS); // User deposits 10 USDC
    uint256 usdcBorrowAmount = 90 * (10 ** USDC_DECIMALS); // User wants to borrow 50 USDC

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    //Deposits USDC
    usdc.approve(address(lendingPool), usdcDepositAmount);
    lendingPool.deposit(address(usdc), usdcDepositAmount);
    vm.stopPrank();

    // --- Pre-Borrow Check ---
    // Collateral: 100 DAI ($100) + 10 USDC ($10) = $110 total collateral USD (at oracle precision)
    // Borrowing Power: ($100 * 0.75) + ($10 * 0.75) = $75 + $7.5 = $82.5 USD (at oracle precision)
    // Amount to borrow: 90 USDC = $90 USD. $90 > $82.5, so borrow should not be allowed.

    uint256 expectedTotalCollateralUSD = (daiDepositAmount * daiPrice) /
      (10 ** DAI_DECIMALS) +
      (usdcDepositAmount * usdcPrice) /
      (10 ** USDC_DECIMALS);
    assertEq(
      lendingPool.getUserTotalCollateralUSD(user1),
      expectedTotalCollateralUSD,
      'User1 total collateral mismatch'
    );

    // --- User1 Borrows USDC ---
    vm.startPrank(user1);
    vm.expectRevert('Borrow exceeds available credit');
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();
  }

  function test_P3_Fail_CanBorrow_SufficientCollateral() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 usdcDepositAmount = 10 * (10 ** USDC_DECIMALS); // User deposits 10 USDC
    uint256 usdcBorrowAmount = 50 * (10 ** USDC_DECIMALS); // User wants to borrow 50 USDC

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    //Deposits USDC
    usdc.approve(address(lendingPool), usdcDepositAmount);
    lendingPool.deposit(address(usdc), usdcDepositAmount);
    vm.stopPrank();

    // --- Pre-Borrow Check ---
    assertTrue(
      lendingPool.getUserAvailableBorrowsUSD(user1) >=
        (usdcBorrowAmount * usdcPrice) / (10 ** USDC_DECIMALS),
      'Pre-borrow: Not enough available borrow USD'
    );

    uint256 scaledAmount = (usdcBorrowAmount * lendingPool.RAY()) / (10 ** USDC_DECIMALS);

    // --- User1 Borrows USDC ---
    vm.startPrank(user1);
    vm.expectEmit(true, true, false, false, address(lendingPool));
    emit Borrowed(address(usdc), user1, usdcBorrowAmount, scaledAmount, block.timestamp);
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();

    // --- Assertions ---
    assertEq(
      lendingPool.getEffectiveUserBorrowBalance(address(usdc), user1),
      usdcBorrowAmount,
      'User1 USDC borrow balance mismatch'
    );
  }

  function test_P3_Fail_CannotBorrow_InsufficientPoolLiquidity() public {
    // --- Constants for clarity
    uint256 usdcBorrowAmount = 500 * (10 ** USDC_DECIMALS); // User wants to borrow 500 USDC
    uint256 largeDaiCollateral = 700 * (10 ** DAI_DECIMALS); // Sufficient DAI collateral for $500 borrow (LTV 75%)

    // --- Admin Setup ---
    vm.startPrank(admin);
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);
    priceOracle.setAssetPrice(address(dai), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    priceOracle.setAssetPrice(address(usdc), 1 * (10 ** ORACLE_PRICE_DECIMALS));

    // Ensure USDC pool has very little liquidity.
    // First, admin withdraws the USDC liquidity added during global setUp.
    uint256 setupUsdcLiquidity = 10000 * (10 ** USDC_DECIMALS); // Amount admin deposited in setUp
    try lendingPool.withdraw(address(usdc), setupUsdcLiquidity) {} catch {}

    // Then, admin deposits a small known amount of USDC for this test.
    uint256 adminTargetUsdcLiquidityInPool = 100 * (10 ** USDC_DECIMALS); // Pool should have 100 USDC
    uint256 adminUsdcBalance = usdc.balanceOf(admin);
    if (adminUsdcBalance < adminTargetUsdcLiquidityInPool) {
      usdc.mint(admin, adminTargetUsdcLiquidityInPool - adminUsdcBalance); // Mint only the shortfall
    }
    usdc.approve(address(lendingPool), adminTargetUsdcLiquidityInPool);
    lendingPool.deposit(address(usdc), adminTargetUsdcLiquidityInPool);
    vm.stopPrank();

    // --- User1 Deposits Sufficient DAI Collateral ---
    vm.startPrank(user1);
    dai.approve(address(lendingPool), largeDaiCollateral);
    lendingPool.deposit(address(dai), largeDaiCollateral); // Use largeDaiCollateral
    vm.stopPrank();

    // --- User1 Tries to Borrow USDC (more than pool liquidity, but collateral is sufficient) ---
    vm.startPrank(user1);
    vm.expectRevert(bytes('LendingPool: Insufficient pool liquidity'));
    lendingPool.borrow(address(usdc), usdcBorrowAmount); // Trying to borrow 500 USDC, pool only has 100 USDC
    vm.stopPrank();
  }

  // --- Repay Tests ---
  function test_P3_UserCanRepay_FullAmount() public {
    // --- 常量与初始设置 ---
    uint256 daiCollateralAmount = 200 * (10 ** DAI_DECIMALS);
    uint256 usdcLiquidityForPoolByAdmin = 100 * (10 ** USDC_DECIMALS); // Admin 提供流动性
    uint256 usdcToBorrowUser1 = 50 * (10 ** USDC_DECIMALS); // User1 借 50 USDC
    uint256 usdcToRepayAttemptUser1 = 50 * (10 ** USDC_DECIMALS); // User1 尝试还 50 USDC

    // --- 1. Admin 设置 ---
    // (已在全局 setUp 完成：配置资产、价格、利率策略等)
    // 如果全局 setUp 没有 mint 足够的 USDC 给 admin，这里需要 mint

    vm.prank(admin);
    if (usdc.balanceOf(admin) < usdcLiquidityForPoolByAdmin) {
      usdc.mint(admin, usdcLiquidityForPoolByAdmin - usdc.balanceOf(admin));
    }
    usdc.approve(address(lendingPool), usdcLiquidityForPoolByAdmin);
    lendingPool.deposit(address(usdc), usdcLiquidityForPoolByAdmin); // Admin 存入USDC作为池子流动性
    vm.stopPrank();

    // --- 2. User1 存入抵押品 (DAI) ---
    vm.startPrank(user1);
    // 确保 user1 有 DAI
    if (dai.balanceOf(user1) < daiCollateralAmount) {
      vm.prank(admin);
      dai.mint(user1, daiCollateralAmount - dai.balanceOf(user1));
      vm.startPrank(user1);
    }
    dai.approve(address(lendingPool), daiCollateralAmount);
    lendingPool.deposit(address(dai), daiCollateralAmount);
    vm.stopPrank();

    // --- 3. User1 成功借款 USDC ---
    vm.startPrank(user1);
    lendingPool.borrow(address(usdc), usdcToBorrowUser1);
    vm.stopPrank();

    // 获取借款后的初始债务 (此时利息几乎为0)
    // 注意：即使在同一区块，如果_updateState被多次调用，微小的利息也可能产生。
    // 为了精确，我们在还款前再获取一次"当前应还款额"。
    uint256 debtPrincipal = usdcToBorrowUser1; // 理论上的本金

    // --- 4. User1 准备还款 ---
    // 确保 User1 钱包 (EOA) 中有足够的 USDC 来还款。
    // User1 借了50 USDC，所以钱包里多了50 USDC。他现在要还这50 USDC。
    uint256 userUsdcWalletBalanceBeforeRepay = usdc.balanceOf(user1);
    require(
      userUsdcWalletBalanceBeforeRepay >= debtPrincipal,
      'User1 does not have enough USDC to repay principal'
    );

    uint256 poolUsdcHoldingBalanceBeforeRepay = usdc.balanceOf(address(lendingPool));
    // 获取 user1 在还款前的 scaled borrow 和 pool 的 total scaled borrows
    (, , , , , , , , , , , uint256 totalScaledBorrowsPoolBeforeRepay, , ) = lendingPool.assetData(
      address(usdc)
    );
    uint256 userScaledBorrowBeforeRepay = lendingPool.getScaledUserBorrowBalance(
      address(usdc),
      user1
    );

    // --- 5. User1 执行还款 ---
    vm.startPrank(user1);
    usdc.approve(address(lendingPool), usdcToRepayAttemptUser1);

    // 在还款前，获取精确的当前应还债务（可能包含极微量利息）
    uint256 currentDebtToRepayWithMinimalInterest = lendingPool.getEffectiveUserBorrowBalance(
      address(usdc),
      user1
    );
    // 对于"全额还款"测试，我们希望偿还所有当前债务
    // 如果 usdcToRepayAttemptUser1 设置为 debtPrincipal，这里 actualRepayAmount 将是 currentDebtToRepayWithMinimalInterest
    // 如果我们只希望偿还本金部分，且合约允许，则用debtPrincipal。但合约repay会尝试清掉所有currentDebt。
    // 所以，actualRepayAmount 将是 currentDebtToRepayWithMinimalInterest（如果repayAttempt >= 它）
    uint256 actualRepayAmount = Math.min(
      usdcToRepayAttemptUser1,
      currentDebtToRepayWithMinimalInterest
    );
    // 如果我们坚持测试"只还本金50"，但实际有微量利息，那么债务不会清零。
    // 这个测试的目的应该是"全额还清当前所有债务"，所以 actualRepayAmount 应该是 currentDebtToRepayWithMinimalInterest
    // 并且 usdcToRepayAttemptUser1 应该至少等于 currentDebtToRepayWithMinimalInterest

    // 让我们假设我们尝试还清所有当前债务
    actualRepayAmount = currentDebtToRepayWithMinimalInterest;
    // 确保 user1 钱包有这么多钱并且 approve 了这么多
    if (usdc.balanceOf(user1) < actualRepayAmount) {
      // 再次检查，因为利息可能使债务略增
      vm.stopPrank();
      vm.prank(admin);
      usdc.mint(user1, actualRepayAmount - usdc.balanceOf(user1));
      vm.startPrank(user1);
    }
    if (usdc.allowance(user1, address(lendingPool)) < actualRepayAmount) {
      usdc.approve(address(lendingPool), actualRepayAmount);
    }

    // 计算期望的 scaledAmountRepaid
    // variableBorrowIndex 在 repay 函数内部的 _updateState 调用后确定
    // 为了在模板中得到精确值，需要在 repay 前模拟或获取它。
    // 但由于 checkData=false，我们只需要结构正确。
    (, , , , , , , uint256 variableBorrowIndex_atRepay, , , , , , ) = lendingPool.assetData(
      address(usdc)
    ); // 获取最新的（但可能还未在当前tx中更新的）指数
    uint256 expectedScaledAmountRepaid = (actualRepayAmount * lendingPool.RAY()) /
      variableBorrowIndex_atRepay;
    if (variableBorrowIndex_atRepay == 0) expectedScaledAmountRepaid = actualRepayAmount; // Should not happen
    // 精确的尘埃处理:
    if (
      actualRepayAmount == currentDebtToRepayWithMinimalInterest &&
      expectedScaledAmountRepaid < userScaledBorrowBeforeRepay
    ) {
      expectedScaledAmountRepaid = userScaledBorrowBeforeRepay; // 如果全还，scaled balance应清零
    }

    vm.expectEmit(true, true, true, false, address(lendingPool));
    emit Repaid(
      address(usdc),
      user1,
      user1,
      actualRepayAmount, // 实际偿还的底层资产数量
      expectedScaledAmountRepaid, // 对应的缩放数量
      block.timestamp
    );

    lendingPool.repay(address(usdc), actualRepayAmount); // 偿还当前全部债务
    vm.stopPrank();

    // --- 6. 断言还款后的状态 ---
    assertEq(
      lendingPool.getEffectiveUserBorrowBalance(address(usdc), user1),
      0,
      'User1 USDC effective borrow balance should be 0 after full repay'
    );
    assertEq(
      usdc.balanceOf(user1),
      userUsdcWalletBalanceBeforeRepay - actualRepayAmount,
      'User1 EOA USDC balance mismatch after repay'
    );
    assertEq(
      usdc.balanceOf(address(lendingPool)),
      poolUsdcHoldingBalanceBeforeRepay + actualRepayAmount,
      'LendingPool USDC holding balance mismatch after repay'
    );

    ILendingPool.AssetDataReturn memory assetData = lendingPool.getAssetData(address(usdc));
    uint256 totalScaledBorrowsPoolAfterRepay = assetData.totalScaledVariableBorrows;
    assertEq(
      totalScaledBorrowsPoolAfterRepay,
      totalScaledBorrowsPoolBeforeRepay - expectedScaledAmountRepaid,
      'Total scaled borrows mismatch after repay'
    );

    // 假设这是 user1 唯一的债务
    assertEq(
      lendingPool.getUserTotalDebtUSD(user1),
      0,
      'User1 total debt USD should be zero after full repay of only debt'
    );
  }

  function test_P3_UserCanRepay_PartialAmount() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 usdcDepositAmount = 100 * (10 ** USDC_DECIMALS); // User deposits 10 USDC
    uint256 usdcBorrowAmount = 50 * (10 ** USDC_DECIMALS); // User wants to borrow 50 USDC
    uint256 usdcRepayAmount = 20 * (10 ** USDC_DECIMALS); // User wants to repay 50 USDC
    //如果还款的钱大于欠款，合约本身不会进行"退款"操作。 用户钱包里只会被扣除实际欠款的部分。

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    //Deposit USDC
    usdc.approve(address(lendingPool), usdcDepositAmount);
    lendingPool.deposit(address(usdc), usdcDepositAmount);

    // --- User1 Borrows USDC ---
    vm.startPrank(user1);
    usdc.approve(address(lendingPool), usdcBorrowAmount);
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();

    // --- User1 Repays USDC ---

    uint256 userUsdcBalanceBefore = usdc.balanceOf(user1);
    uint256 poolUsdcBalanceBefore = usdc.balanceOf(address(lendingPool));
    uint256 totalAssetBorrowsBefore = lendingPool.getCurrentTotalActualBorrows(address(usdc));
    uint256 userTotalDebtUSDBefore = lendingPool.getUserTotalDebtUSD(user1);
    uint256 scaledAmount = (usdcRepayAmount * lendingPool.RAY()) / (10 ** USDC_DECIMALS);
    vm.startPrank(user1);
    vm.expectEmit(true, true, true, false, address(lendingPool));
    emit Repaid(address(usdc), user1, user1, usdcRepayAmount, scaledAmount, block.timestamp);

    lendingPool.repay(address(usdc), usdcRepayAmount);
    vm.stopPrank();

    uint256 userUsdcBalanceAfter = usdc.balanceOf(user1);
    uint256 poolUsdcBalanceAfter = usdc.balanceOf(address(lendingPool));
    uint256 totalAssetBorrowsAfter = lendingPool.getCurrentTotalActualBorrows(address(usdc));
    uint256 userTotalDebtUSDAfter = lendingPool.getUserTotalDebtUSD(user1);

    uint256 repayAmountUSD = (usdcRepayAmount * usdcPrice) / (10 ** USDC_DECIMALS);

    // --- Assertions ---
    // 1. Check internal repay balance record
    assertEq(
      userUsdcBalanceBefore - userUsdcBalanceAfter,
      usdcRepayAmount,
      'User1 USDC balance after repay mismatch'
    );
    assertEq(
      poolUsdcBalanceAfter - poolUsdcBalanceBefore,
      usdcRepayAmount,
      'LendingPool USDC balance after repay mismatch'
    );
    assertEq(
      totalAssetBorrowsBefore - totalAssetBorrowsAfter,
      usdcRepayAmount,
      'LendingPool USDC totalAssetBorrow after repay mismatch'
    );
    assertEq(
      userTotalDebtUSDBefore - userTotalDebtUSDAfter,
      repayAmountUSD,
      'LendingPool userTotalDebtUSD after repay mismatch'
    );
  }

  function test_P3_Fail_CannotRepay_NoDebt() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 usdcDepositAmount = 100 * (10 ** USDC_DECIMALS); // User deposits 10 USDC
    uint256 usdcRepayAmount = 20 * (10 ** USDC_DECIMALS); // User wants to repay 50 USDC

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    priceOracle.setAssetPrice(address(usdc), 1 * (10 ** ORACLE_PRICE_DECIMALS));
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    //Deposit USDC
    usdc.approve(address(lendingPool), usdcDepositAmount);
    lendingPool.deposit(address(usdc), usdcDepositAmount);

    // --- User1 Repays USDC ---
    vm.startPrank(user1);
    usdc.approve(address(lendingPool), usdcRepayAmount);
    vm.expectRevert('LendingPool: No borrowings to repay');
    lendingPool.repay(address(usdc), usdcRepayAmount);
    vm.stopPrank();
  }

  function test_P3_ViewFunctions_ReturnCorrectBorrowData() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    // uint256 usdcDepositAmount = 100 * (10 ** USDC_DECIMALS); // User did NOT deposit USDC in this test path
    uint256 usdcBorrowAmount = 50 * (10 ** USDC_DECIMALS); // User wants to borrow 50 USDC

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500); // LTV 75%, LT 80%
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    // --- User1 Borrows USDC ---
    usdc.approve(address(lendingPool), usdcBorrowAmount); // Approve pool for repayment
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();

    uint256 borrowBalance = lendingPool.getEffectiveUserBorrowBalance(address(usdc), user1);
    uint256 totalDebtUSD = lendingPool.getUserTotalDebtUSD(user1);
    uint256 borrowingPowerUSD = lendingPool.getUserBorrowPowerUSD(user1);
    uint256 availableBorrowsUSD = lendingPool.getUserAvailableBorrowsUSD(user1);
    uint256 healthFactor = lendingPool.calculateHealthFactor(user1);

    uint256 expectedDaiCollateralUSD = (daiDepositAmount * daiPrice) / (10 ** DAI_DECIMALS);

    ILendingPool.AssetDataReturn memory daiData = lendingPool.getAssetData(address(dai));
    uint256 daiLtvFromTuple = daiData.ltv;
    uint256 expectedBorrowingPowerUSD = (expectedDaiCollateralUSD * daiLtvFromTuple) /
      lendingPool.PERCENTAGE_FACTOR();

    assertEq(borrowBalance, usdcBorrowAmount, 'Borrow balance mismatch');
    assertEq(
      totalDebtUSD,
      (usdcBorrowAmount * usdcPrice) / (10 ** USDC_DECIMALS),
      'Total debt mismatch'
    );
    assertEq(borrowingPowerUSD, expectedBorrowingPowerUSD, 'Borrowing power mismatch');
    assertEq(
      availableBorrowsUSD,
      expectedBorrowingPowerUSD - totalDebtUSD,
      'Available borrows mismatch'
    );

    ILendingPool.AssetDataReturn memory daiDataForHf = lendingPool.getAssetData(address(dai));
    uint256 daiLiquidationThresholdFromTuple = daiDataForHf.liquidationThreshold;

    uint256 expectedHfNumerator = (expectedDaiCollateralUSD * daiLiquidationThresholdFromTuple) /
      lendingPool.PERCENTAGE_FACTOR();
    uint256 expectedHf = (expectedHfNumerator * HEALTH_FACTOR_PRECISION) / totalDebtUSD;
    assertEq(healthFactor, expectedHf, 'Health factor mismatch');
  }

  function test_P3_Withdraw_Fail_IfMakesPositionUnsafe() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 user2UsdcDepositAmount = 100 * (10 ** USDC_DECIMALS);
    uint256 daiWithdrawAmount = 50 * (10 ** DAI_DECIMALS);
    uint256 usdcBorrowAmount = 60 * (10 ** USDC_DECIMALS); // User wants to borrow 50 USDC

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);

    // --- User2 Deposits Collateral ---
    vm.startPrank(user2);
    //Deposit Usdc
    usdc.approve(address(lendingPool), user2UsdcDepositAmount);
    lendingPool.deposit(address(usdc), user2UsdcDepositAmount);
    vm.stopPrank();

    // --- User1 Borrows USDC ---
    vm.startPrank(user1);
    usdc.approve(address(usdc), usdcBorrowAmount);
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();

    // --- User1 withdraws DAI ---
    vm.prank(user1);
    vm.expectRevert('LendingPool: Health factor below minimum');
    lendingPool.withdraw(address(dai), daiWithdrawAmount);
    // 如果取出成功，剩余DAI为50 DAI (抵押价值$50, 有效抵押价值 $50 * 80% = $40)。
    // 剩余债务为60 USDC
    // 健康因子 = 有效抵押价值 / 债务 = $40 / $60 = 0.666666666666666666
  } //(关键测试！)

  function test_P3_Withdraw_Success_IfPositionRemainsSafe() public {
    // --- Constants for clarity
    uint256 daiDepositAmount = 100 * (10 ** DAI_DECIMALS); // User deposits 100 DAI
    uint256 daiWithdrawAmount = 30 * (10 ** DAI_DECIMALS);
    uint256 usdcBorrowAmount = 30 * (10 ** USDC_DECIMALS); // User wants to borrow 30 USDC (not 50)

    // Assume prices are $1 per DAI and $1 per USDC for simplicity
    uint256 daiPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);
    uint256 usdcPrice = 1 * (10 ** ORACLE_PRICE_DECIMALS);

    //--- Admin Setup ---
    vm.startPrank(admin);
    //1. Configure assets in LendingPool
    configurator.addAsset(address(dai), 7500, 8000, address(daiRateStrategy), 1000, 500);
    configurator.addAsset(address(usdc), 7500, 8000, address(usdcRateStrategy), 1000, 500);

    //2. Set asset prices in PriceOracle
    priceOracle.setAssetPrice(address(dai), daiPrice);
    priceOracle.setAssetPrice(address(usdc), usdcPrice);
    vm.stopPrank();

    // --- User1 Deposits Collateral ---
    vm.startPrank(user1);
    //Deposit DAI
    dai.approve(address(lendingPool), daiDepositAmount);
    lendingPool.deposit(address(dai), daiDepositAmount);
    // --- User1 Borrows USDC ---
    // User1 needs USDC in their wallet to approve for borrowing, but borrow takes from pool.
    // Mint some USDC to user1 for the approve call, though it's not strictly necessary for the borrow to succeed if pool has liquidity.
    // usdc.mint(user1, usdcBorrowAmount); //This is not needed as borrow does not take from user wallet for the borrowed amount
    usdc.approve(address(lendingPool), usdcBorrowAmount); // Approve the pool to manage USDC (e.g. for future repayments, not borrow itself)
    lendingPool.borrow(address(usdc), usdcBorrowAmount);
    vm.stopPrank();

    uint256 balanceBeforeWithdraw = dai.balanceOf(user1);
    uint256 totalDaiDepositsBefore = lendingPool.getCurrentTotalActualDeposits(address(dai));

    uint256 scaledAmount = (daiWithdrawAmount * lendingPool.RAY()) / (10 ** DAI_DECIMALS);
    // --- User1 withdraws DAI ---
    vm.startPrank(user1);
    vm.expectEmit(true, true, false, false, address(lendingPool));
    emit Withdrawn(address(dai), user1, daiWithdrawAmount, scaledAmount, block.timestamp);
    lendingPool.withdraw(address(dai), daiWithdrawAmount);
    vm.stopPrank();

    uint256 User1DaiBalanceAfter = dai.balanceOf(user1);
    assertEq(
      User1DaiBalanceAfter,
      balanceBeforeWithdraw + daiWithdrawAmount,
      'User1 DAI balance after withdraw mismatch'
    );

    assertEq(
      lendingPool.getCurrentTotalActualDeposits(address(dai)),
      totalDaiDepositsBefore - daiWithdrawAmount,
      'Total deposits of DAI mismatch'
    );

    uint256 healthFactorAfter = lendingPool.calculateHealthFactor(user1);
    require(
      healthFactorAfter >= MINIMUM_HEALTH_FACTOR, // Use constant
      'Health factor should be greater than or equal to minimum health factor'
    );
  }

  //--- Helper function to get current effective balances for assertions ---
  function getEffectiveBalances(
    address asset,
    address user
  ) internal view returns (uint256 depositBal, uint256 borrowBal) {
    depositBal = lendingPool.getEffectiveUserDeposit(asset, user);
    borrowBal = lendingPool.getEffectiveUserBorrowBalance(asset, user);
  }

  function test_P4_Deposit_InterestAccures() public {
    uint256 initialDeposit = 1000 * (10 ** DAI_DECIMALS);
    uint256 borrowAmount = 500 * (10 ** DAI_DECIMALS); // 添加借款以产生利息

    //User1 deposit DAI
    vm.startPrank(user1);
    dai.approve(address(lendingPool), initialDeposit);
    lendingPool.deposit(address(dai), initialDeposit);
    vm.stopPrank();

    // User2 borrows DAI to产生利息
    vm.startPrank(user2);
    // 先存入抵押品
    usdc.approve(address(lendingPool), 1000 * (10 ** USDC_DECIMALS));
    lendingPool.deposit(address(usdc), 1000 * (10 ** USDC_DECIMALS));
    // 然后借DAI
    lendingPool.borrow(address(dai), borrowAmount);
    vm.stopPrank();

    (uint256 depositBalBeforeTime, ) = getEffectiveBalances(address(dai), user1);
    assertEq(depositBalBeforeTime, initialDeposit, 'Initial deposit amount mismatch');

    // Advance time by 1 year
    vm.warp(block.timestamp + 365 days);

    // Trigger state update for DAI
    vm.startPrank(user2);
    dai.approve(address(lendingPool), 1 * (10 ** (DAI_DECIMALS - 6))); // Approve 0.000001 DAI
    lendingPool.deposit(address(dai), 1 * (10 ** (DAI_DECIMALS - 6))); // Tiny deposit to trigger state update
    vm.stopPrank();

    // check user1's balance again
    (uint256 depositBalAfterTime, ) = getEffectiveBalances(address(dai), user1);

    assertTrue(
      depositBalAfterTime > initialDeposit,
      'Deposit balance should have accrued interest'
    );

    //User1 withdraw all
    vm.startPrank(user1);
    uint256 userDaiBalanceBeforeWithdraw = dai.balanceOf(user1);
    lendingPool.withdraw(address(dai), depositBalAfterTime);
    vm.stopPrank();

    assertTrue(
      lendingPool.getEffectiveUserDeposit(address(dai), user1) <= 1, // Allow for dust amount
      'User1 DAI deposit should be 0 or dust after full withdraw'
    );

    assertEq(
      dai.balanceOf(user1),
      userDaiBalanceBeforeWithdraw + depositBalAfterTime,
      'User1 DAI balance incorrect after withdraw'
    );
  }

  function test_P4_Borrow_InterestAccrues() public {
    uint256 daiCollateralUser2 = 2000 * (10 ** DAI_DECIMALS);
    uint256 usdcLiquidityUser1 = 1000 * (10 ** USDC_DECIMALS);
    uint256 usdcToBorrowUser2 = 500 * (10 ** USDC_DECIMALS);
    assertEq(dai.owner(), admin, 'Admin is not DAI owner');
    assertEq(usdc.owner(), admin, 'Admin is not USDC owner');
    // Admin mint DAI to user2
    vm.prank(dai.owner());
    dai.mint(user2, daiCollateralUser2);

    // User1 provides USDC liquidity
    vm.startPrank(user1);
    usdc.approve(address(lendingPool), usdcLiquidityUser1);
    lendingPool.deposit(address(usdc), usdcLiquidityUser1);
    vm.stopPrank();

    // User2 deposits DAI as collateral and borrows USDC
    vm.startPrank(user2);
    dai.approve(address(lendingPool), daiCollateralUser2);
    lendingPool.deposit(address(dai), daiCollateralUser2);
    lendingPool.borrow(address(usdc), usdcToBorrowUser2);
    vm.stopPrank();

    uint256 borrowBalBeforeTime = lendingPool.getEffectiveUserBorrowBalance(address(usdc), user2);
    assertEq(borrowBalBeforeTime, usdcToBorrowUser2, 'Initial borrow amount mismatch');

    // Advance time by one year
    vm.warp(block.timestamp + 365 days);

    // Trigger interest accrual by performing a minimal deposit
    uint256 triggerDepositAmount = 100; // Ensure it's at least 1
    vm.prank(usdc.owner());
    usdc.mint(user1, triggerDepositAmount);

    vm.startPrank(user1);
    usdc.approve(address(lendingPool), triggerDepositAmount);
    lendingPool.deposit(address(usdc), triggerDepositAmount);
    vm.stopPrank();

    // Calculate the current debt with interest
    uint256 currentDebtWithInterest = lendingPool.getEffectiveUserBorrowBalance(
      address(usdc),
      user2
    );
    assertTrue(currentDebtWithInterest > usdcToBorrowUser2, 'Interest did not accrue');

    // Ensure user2 has enough USDC to repay
    uint256 userUsdcBalance = usdc.balanceOf(user2);
    if (userUsdcBalance < currentDebtWithInterest) {
      vm.prank(usdc.owner());
      usdc.mint(user2, currentDebtWithInterest - userUsdcBalance);
    }

    // User2 repays the debt
    vm.startPrank(user2);
    usdc.approve(address(lendingPool), currentDebtWithInterest);
    lendingPool.repay(address(usdc), currentDebtWithInterest);
    vm.stopPrank();

    // Assert the debt is cleared
    uint256 finalDebt = lendingPool.getEffectiveUserBorrowBalance(address(usdc), user2);
    assertEq(finalDebt, 0, 'Debt was not fully repaid');
  }

  //  function P5 about liquidation
  function test_P5_LiquidationCall_Successful_FullDebtCover() public {
    // --- Aliases & Initial Balances ---
    address userToLiquidate = user1;
    address liquidator = user2;
    uint256 initialDaiDepositUser1 = 200 * (10 ** DAI_DECIMALS); // e.g., $200
    uint256 initialUsdcBorrowUser1 = 120 * (10 ** USDC_DECIMALS); // e.g., $120 debt
    // Ensure liquidator (user2) has enough USDC to cover the debt
    vm.startPrank(admin);
    usdc.mint(liquidator, initialUsdcBorrowUser1 + (10 * (10 ** USDC_DECIMALS))); // 多给10 USDC 余量
    vm.stopPrank();

    // --- Setup: User1 deposits DAI, borrows USDC ---
    vm.startPrank(userToLiquidate);
    dai.approve(address(lendingPool), initialDaiDepositUser1);
    lendingPool.deposit(address(dai), initialDaiDepositUser1);
    vm.stopPrank();
    // 保证池子里有流动性，钱够

    vm.startPrank(admin);
    uint256 poolUsdcLiquidity = 200 * (10 ** USDC_DECIMALS);
    if (usdc.balanceOf(admin) < poolUsdcLiquidity) {
      // 确保 admin 有足够的USDC
      usdc.mint(admin, poolUsdcLiquidity - usdc.balanceOf(admin));
    }

    usdc.approve(address(lendingPool), poolUsdcLiquidity);
    lendingPool.deposit(address(usdc), poolUsdcLiquidity); // Admin adds USDC liquidity
    vm.stopPrank();

    vm.startPrank(userToLiquidate); // User1 borrows
    lendingPool.borrow(address(usdc), initialUsdcBorrowUser1);
    vm.stopPrank();

    // --- Make position unhealhty: Drop DAI price ---
    vm.startPrank(admin);
    priceOracle.setAssetPrice(address(dai), 70 * (10 ** (ORACLE_PRICE_DECIMALS - 2))); // $0.70
    vm.stopPrank();

    // --- Prepare for Liquidation ---
    uint256 debtToCover = lendingPool.getEffectiveUserBorrowBalance(address(usdc), userToLiquidate);
    require(debtToCover > 0, 'User should have debt');

    // 如果 debtToCover 因为利息变得比 initialUsdcBorrowUser1 多，确保 liquidator 有足够的 USDC
    if (usdc.balanceOf(liquidator) < debtToCover) {
      vm.prank(admin);
      usdc.mint(liquidator, debtToCover - usdc.balanceOf(liquidator));
      vm.stopPrank();
    }

    uint256 liquidatorUsdcBalanceBefore = usdc.balanceOf(liquidator);
    uint256 liquidatorDaiBalanceBefore = dai.balanceOf(liquidator);
    uint256 user1DaiScaledDepositBefore = lendingPool.getScaledUserDeposit(
      address(dai),
      userToLiquidate
    );

    // --- Liquidator performs liquidationCall ---
    // LendingPool.AssetData memory daiAssetInfo = lendingPool.assetData(address(dai));
    // LendingPool.AssetData memory usdcAssetInfo = lendingPool.assetData(address(usdc));

    // 获取 dai 的资产信息
    ILendingPool.AssetDataReturn memory daiData = lendingPool.getAssetData(address(dai));
    uint8 daiDecimals = daiData.decimals;
    uint256 daiLiquidationBonus = daiData.liquidationBonus;

    // 获取 usdc 的资产信息
    ILendingPool.AssetDataReturn memory usdcData = lendingPool.getAssetData(address(usdc));
    uint8 usdcDecimals = usdcData.decimals;

    uint256 debtAssetPrice = priceOracle.getAssetPrice(address(usdc));
    uint256 collateralAssetPrice = priceOracle.getAssetPrice(address(dai));
    require(debtAssetPrice > 0 && collateralAssetPrice > 0, 'Oracle prices must be valid');

    uint256 debtToCoverValueUSD = (debtToCover * debtAssetPrice) / (10 ** usdcDecimals);
    uint256 collateralToReceiveValueUSD = (debtToCoverValueUSD *
      (PERCENTAGE_FACTOR + daiLiquidationBonus)) / PERCENTAGE_FACTOR;
    uint256 expectedCollateralToSeize = (collateralToReceiveValueUSD * (10 ** daiDecimals)) /
      collateralAssetPrice;

    bool receiveUnderlyingCollateral = true;

    vm.startPrank(liquidator);
    // ***** 关键修复：添加 approve *****
    usdc.approve(address(lendingPool), debtToCover);
    // ILendingPool.LiquidationCall(collateralAsset, debtAsset, user, debtToCover, liquidatedCollateralAmount, liquidator, timestamp)
    vm.expectEmit(true, true, true, false, address(lendingPool)); // 检查3个topics, 不检查data
    emit LiquidationCall(
      address(dai), // collateralAsset (indexed)
      address(usdc), // debtAsset (indexed)
      userToLiquidate, // user (indexed)
      debtToCover, // debtToCover (data)
      expectedCollateralToSeize, // liquidatedCollateralAmount (data)
      liquidator,
      receiveUnderlyingCollateral, // receiveUnderlyingCollateral (data)
      block.timestamp // timestamp (data) - checkData=false 时，这里的值不影响匹配，但参数必须存在
    );

    lendingPool.liquidationCall(
      address(dai),
      address(usdc),
      userToLiquidate,
      debtToCover,
      receiveUnderlyingCollateral
    );
    vm.stopPrank();

    // --- Assertions ---
    assertEq(
      lendingPool.getEffectiveUserBorrowBalance(address(usdc), userToLiquidate),
      0,
      'User1 USDC debt should be zero'
    );
    assertTrue(
      lendingPool.getScaledUserDeposit(address(dai), userToLiquidate) <=
        user1DaiScaledDepositBefore,
      'User1 DAI collateral should decrease'
    );
    assertEq(
      usdc.balanceOf(liquidator),
      liquidatorUsdcBalanceBefore - debtToCover,
      'Liquidator USDC balance incorrect'
    );
    assertEq(
      dai.balanceOf(liquidator),
      liquidatorDaiBalanceBefore + expectedCollateralToSeize,
      'Liquidator DAI balance incorrect'
    );
    assertTrue(
      lendingPool.calculateHealthFactor(userToLiquidate) > MINIMUM_HEALTH_FACTOR ||
        lendingPool.getUserTotalDebtUSD(userToLiquidate) == 0,
      'User HF should improve or debt cleared'
    );
    console2.log('HF before liquidation:', lendingPool.calculateHealthFactor(userToLiquidate));
    console2.log(
      'User1 debt:',
      lendingPool.getEffectiveUserBorrowBalance(address(usdc), userToLiquidate)
    );
    console2.log(
      'User1 DAI collateral:',
      lendingPool.getScaledUserDeposit(address(dai), userToLiquidate)
    );
  }

  // test_P5_LiquidationCall_Successful_FullDebtCoverForAsset()
  // 场景：UserToLiquidate的HF < 1。LiquidatorUser 偿还 UserToLiquidate 的全部USDC债务。
  // 操作：LiquidatorUser 调用 liquidationCall，_debtToCoverInUnderlying 设置为 UserToLiquidate 的全部USDC债务额。
  // 断言：
  // LiquidationCall 事件被正确发出。
  // UserToLiquidate 的USDC债务变为0。
  // UserToLiquidate 的DAI抵押品按 (债务价值USD * (1 + 清算奖励率)) / DAI价格USD 的数量减少。
  // LiquidatorUser 的USDC余额减少（用于还债），DAI余额增加（获得的抵押品）。
  // 相关的 scaledUserBorrows, totalScaledVariableBorrows, scaledUserDeposits, totalScaledDeposits 被正确更新。
  // UserToLiquidate 的健康因子得到改善（如果还有其他债务/抵押品）或变为极大值（如果所有债务都清了）。

  // test_P5_LiquidationCall_Successful_PartialDebtCover()
  // 场景：UserToLiquidate的HF < 1。LiquidatorUser 偿还 UserToLiquidate 的部分USDC债务。
  // 操作：LiquidatorUser 调用 liquidationCall，_debtToCoverInUnderlying 设置为 UserToLiquidate 的部分USDC债务额（例如50%）。
  // 断言：类似上面，但债务和抵押品只部分减少。UserToLiquidate 仍有剩余USDC债务。HF应有所改善。

  // test_P5_Fail_LiquidationCall_HealthFactorTooHigh()
  // 场景：UserToLiquidate的HF >= 1 (健康状态)。
  // 操作：LiquidatorUser 尝试调用 liquidationCall。
  // 断言：交易应 revert，错误消息为 "LendingPool: Position cannot be liquidated (HF healthy)"。

  // test_P5_Fail_LiquidationCall_NotEnoughUserCollateralToSeize()
  // 场景：UserToLiquidate的HF < 1。但是，他拥有的特定抵押品资产（例如DAI）的数量，不足以覆盖 (清算者指定的债务偿还额对应的价值 * (1 + 清算奖励率))。
  // 操作：LiquidatorUser 调用 liquidationCall。
  // 断言：交易应 revert，错误消息为 "LendingPool: Not enough user collateral to seize for liquidation"。

  // test_P5_Fail_LiquidationCall_DebtToCoverIsZero()
  // 操作：LiquidatorUser 调用 liquidationCall，但 _debtToCoverInUnderlying 为 0。
  // 断言：交易应 revert，错误消息为 "LendingPool: Debt to cover cannot be zero"。

  // test_P5_Fail_LiquidationCall_UserHasNoDebtOfAsset()
  // 场景：UserToLiquidate的HF < 1 (可能因为其他资产的债务)，但他并没有借指定的 _debtAsset。
  // 操作：LiquidatorUser 调用 liquidationCall 尝试清算一个用户没有欠的 _debtAsset。
  // 断言：交易应 revert，错误消息为 "LendingPool: User has no debt of specified asset to liquidate"。

  // --- TEST for FlahsLoan ---
  function setUpFlashLoanTests() public {
    flashLoanReceiver = new MockFlashLoanReceiver(address(lendingPool));

    // Ensure USDC pool has only the specific liquidity for flash loan tests.
    // First, admin withdraws the USDC liquidity added during global setUp, if any remaining.
    vm.startPrank(admin);
    uint256 setupUsdcLiquidityAdmin = 10000 * (10 ** USDC_DECIMALS); // Amount admin deposited in global setUp
    try lendingPool.withdraw(address(usdc), setupUsdcLiquidityAdmin) {} catch {}

    // Then, admin (or another user) deposits the specific amount for flash loan tests.
    uint256 usdcLiquidityForFlashloan = 200 * (10 ** USDC_DECIMALS);
    // Ensure admin has enough USDC to deposit this (mint if necessary from global supply)
    uint256 adminUsdcBalance = usdc.balanceOf(admin);
    if (adminUsdcBalance < usdcLiquidityForFlashloan) {
      usdc.mint(admin, usdcLiquidityForFlashloan - adminUsdcBalance); // Mint only the shortfall
    }
    usdc.approve(address(lendingPool), usdcLiquidityForFlashloan);
    lendingPool.deposit(address(usdc), usdcLiquidityForFlashloan);
    vm.stopPrank();
  }

  function test_P7_FlashLoan_Successful() public {
    setUpFlashLoanTests();
    flashLoanReceiver.setNextAction(MockFlashLoanReceiver.Action.REPAY_WITH_APPROVAL);

    uint256 feeExpected = (FLASHLOAN_TEST_AMOUNT * lendingPool.FLASHLOAN_FEE_BASIS_POINTS()) /
      lendingPool.PERCENTAGE_FACTOR();

    // 2. 给 receiver 预存本金+fee，确保它有余额来还款
    usdc.mint(address(flashLoanReceiver), FLASHLOAN_TEST_AMOUNT + feeExpected);

    uint256 poolUsdcBalanceBefore = usdc.balanceOf(address(lendingPool));
    uint256 receiverUsdcBalanceBefore = usdc.balanceOf(address(flashLoanReceiver));

    vm.warp(1700000000); // 设置一个已知的时间戳

    vm.startPrank(user1);
    vm.expectEmit(true, true, true, false);
    emit FlashLoan(
      address(flashLoanReceiver),
      user1,
      address(usdc),
      FLASHLOAN_TEST_AMOUNT,
      feeExpected,
      1700000000
    );
    lendingPool.flashLoan(address(flashLoanReceiver), address(usdc), FLASHLOAN_TEST_AMOUNT, '');
    console2.log('Expected fee:', feeExpected);
    vm.stopPrank();

    // Assertions
    assertEq(
      usdc.balanceOf(address(flashLoanReceiver)),
      receiverUsdcBalanceBefore - feeExpected,
      'Receiver USDC balance changed unexpectedly'
    );
    assertEq(
      usdc.balanceOf(address(lendingPool)),
      poolUsdcBalanceBefore + feeExpected,
      'Pool USDC balance did not increase by fee'
    );
  }

  function test_P7_FlashLoan_Fail_FundsNotRepaid() public {
    setUpFlashLoanTests();
    // Receiver returns true, but does not approve/repay (MockFlashLoanReceiver needs more actions for this)
    // For this to fail at safeTransferFrom in LendingPool, receiver must return true but not approve.
    // The current MockFlashLoanReceiver.Action.DO_NOTHING_RETURN_TRUE will cause this.
    flashLoanReceiver.setNextAction(MockFlashLoanReceiver.Action.DO_NOTHING_RETURN_TRUE);

    vm.startPrank(user1);
    // The revert will likely be from the IERC20.safeTransferFrom inside flashLoan
    // e.g., "ERC20: insufficient allowance" or similar, depending on SafeERC20.
    // For an exact match, you'd need to know what SafeERC20 reverts with.
    // Using a generic vm.expectRevert() without arguments checks for any revert.
    vm.expectRevert();
    lendingPool.flashLoan(address(flashLoanReceiver), address(usdc), FLASHLOAN_TEST_AMOUNT, '');
    vm.stopPrank();
  }

  function test_P7_FlashLoan_Fail_InsufficientLiquidity() public {
    setUpFlashLoanTests(); // This now ensures pool has exactly 200 USDC initially for the test sequence

    uint256 amountToBorrow = 5000 * (10 ** USDC_DECIMALS); // More than available (200 USDC)

    vm.startPrank(user1);
    vm.expectRevert(bytes('LendingPool: Not enough liquidity for flash loan'));
    lendingPool.flashLoan(address(flashLoanReceiver), address(usdc), amountToBorrow, '');
    vm.stopPrank();
  }
}
