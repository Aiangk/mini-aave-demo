// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from 'forge-std/Test.sol';
import {ILendingPool} from '../../src/Interfaces/ILendingPool.sol';
import {LendingPool} from '../../src/Core/LendingPool.sol';
import {Configurator} from '../../src/Core/Configurator.sol';
import {PriceOracle} from '../../src/Oracles/PriceOracle.sol';
import {MockERC20} from '../../src/Mocks/MockERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {DefaultInterestRateStrategy} from '../../src/Logic/DefaultInterestRateStrategy.sol';

contract DepositTest is Test {
  event Deposited(
    address indexed asset,
    address indexed user,
    uint256 amount,
    uint256 scaledAmount,
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

  function test_Deposit_fronend() public {
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
}
