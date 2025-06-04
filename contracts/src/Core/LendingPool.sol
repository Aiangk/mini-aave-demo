// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {ILendingPool} from '../Interfaces/ILendingPool.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IPriceOracle} from '../Interfaces/IPriceOracle.sol';
import {IInterestRateStrategy, RateCalculationParams} from '../Interfaces/IInterestRateStrategy.sol';
import {AToken} from '../Tokens/AToken.sol';
import {IAToken} from '../Interfaces/IAToken.sol';
import {IFlashLoanReceiver} from '../Interfaces/IFlashLoanReceiver.sol';
import {console} from 'forge-std/console.sol';

contract LendingPool is ILendingPool, ReentrancyGuard {
  using SafeERC20 for IERC20;

  address public immutable configurator;
  IPriceOracle public immutable priceOracle;

  //Constants for financial calculations
  uint256 public constant RAY = 1e27; //用于利率和指数计算的精度单位
  uint256 public constant SECONDS_PER_YEAR_FOR_RATES = 365 days; // 年化利率转换为秒利率的基准
  uint256 public constant ORACLE_PRICE_DECIMALS = 8; // 价格Oracle的精度
  uint256 public constant PERCENTAGE_FACTOR = 10000; // For LTV, LiqThreshold (e.g., 7500 = 75.00%)
  uint256 public constant HEALTH_FACTOR_PRECISION = 10 ** 18; // 健康因子精度 (例如 1.0 代表 1e18)
  uint256 public constant MINIMUM_HEALTH_FACTOR = 1 * HEALTH_FACTOR_PRECISION; // 最小健康因子
  uint256 public constant FLASHLOAN_FEE_BASIS_POINTS = 9; // 例如 0.09%，9 BPS (Basis Points)
  //Health Factor = (Collateral Value * Liquidation Threshold) / Total Borrowed Value
  // Collateral Value你的总抵押资产价值，
  // Total Borrowed Value你的总借出资产价值
  // Liquidation Threshold你的抵押资产的清算线
  //分子（上限）	抵押物价值 × 清算阈值 —— 系统允许的最大借款值
  //分母（已借）	你实际借走的总资产价值
  //比值（健康因子）	表示当前负债安全程度，越大越安全
  // 健康因子 > 1：健康，抵押物还足以覆盖借款，暂时不会被清算。
  // 健康因子 = 1：临界点，刚好触发清算线，再跌一点就危险。
  // 健康因子 < 1：抵押物价值不再足够，别人可以发起清算你。

  //资产配置结构体，记录信息
  struct AssetData {
    bool isSupported;
    uint8 decimals;
    uint256 ltv;
    uint256 liquidationThreshold;
    address interestRateStrategy; // Address of the interest rate strategy contract for this asset
    uint256 reserveFactor; // Percentage of borrow interest collected as reserves (e.g., 1000 = 10.00%)
    uint256 liquidationBonus;
    // Interest rate indices
    uint256 liquidityIndex; // Cumulative index for suppliers, scaled by RAY
    uint256 variableBorrowIndex; // Cumulative index for borrowers, scaled by RAY
    uint256 lastUpdateTimestamp; // Timestamp of the last interest update for this asset
    // Total amounts
    uint256 totalScaledDeposits; // Total deposits in scaled balance (sum of user scaled deposits)
    uint256 totalScaledVariableBorrows; // Total borrows in scaled balance
    uint256 currentTotalReserves; // Reserves accumulated for this asset (actual underlying)
    address aTokenAddress; // 此资产对应的aToken合约地址
  }

  //asset address => configuration
  mapping(address => AssetData) public assetData;

  mapping(address => mapping(address => uint256)) public scaledUserDeposits;
  mapping(address => mapping(address => uint256)) public scaledUserBorrows;

  address[] public supportedAssetsList; //迭代那些支持的资产，方便抵押计算
  mapping(address => uint256) private supportedAssetIndex; //asset => index in supportedAssetsList (index + 1, 0 means not present)

  modifier onlyConfigurator() {
    require(msg.sender == configurator, 'LendingPool: Caller is not the Configurator');
    _;
  }

  constructor(address _configuratorAddress, address _priceOracleAddress) {
    require(_configuratorAddress != address(0), 'LendingPool:  Invalid Configurator address');
    require(_priceOracleAddress != address(0), 'LendingPool: Invalid Price Oracle address');
    configurator = _configuratorAddress;
    priceOracle = IPriceOracle(_priceOracleAddress);
    require(
      priceOracle.getPriceDecimals() == ORACLE_PRICE_DECIMALS,
      'LendingPool: Oracals misle decimmatch'
    );
  }

  // --- External functions for users ---
  function deposit(address _asset, uint256 _amount) external override nonReentrant {
    _updateState(_asset);
    AssetData storage assetInfo = assetData[_asset];
    require(assetInfo.isSupported, 'LendingPool: Asset not supported');
    require(_amount > 0, 'LendingPool: Amount must be > 0');
    require(assetInfo.aTokenAddress != address(0), 'LendingPool: aToken not configured for asset');
    IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount); // 用户先把底层资产转给LendingPool
    // LendingPool 指示 aToken 给用户铸造相应数量的 aToken
    // aToken.mint() 内部会根据当前的 liquidityIndex 计算需要 mint 的 scaled aToken 数量
    uint256 scaledAmountMinted = AToken(assetInfo.aTokenAddress).mint(
      msg.sender,
      _amount,
      assetInfo.liquidityIndex
    );

    // 更新LendingPool中记录的总缩放存款 (应与aToken的totalSupply一致)
    assetInfo.totalScaledDeposits = AToken(assetInfo.aTokenAddress).getScaledTotalSupply();
    emit Deposited(_asset, msg.sender, _amount, scaledAmountMinted, block.timestamp);
  }

  function withdraw(
    address _asset,
    uint256 _amountToWithdrawUnderlying
  ) external override nonReentrant {
    _updateState(_asset);
    AssetData storage assetInfo = assetData[_asset];
    require(assetInfo.isSupported, 'LendingPool: Asset not supported');
    require(_amountToWithdrawUnderlying > 0, 'LendingPool: Amount must be > 0');
    require(assetInfo.aTokenAddress != address(0), 'LendingPool: aToken not configured for asset');

    AToken aToken = AToken(assetInfo.aTokenAddress);

    // 计算用户当前持有的aToken对应的底层资产总额 (本金+利息)
    uint256 userScaledATokenBalance = aToken.scaledBalanceOf(msg.sender);
    uint256 userCurrentBalanceUnderlying = (userScaledATokenBalance * assetInfo.liquidityIndex) /
      RAY;
    require(
      userCurrentBalanceUnderlying >= _amountToWithdrawUnderlying,
      'LendingPool: Insufficient available balance for withdrawal'
    );

    // 健康因子检查
    // 计算若取款发生，新的有效抵押品价值，并检查健康因子
    uint256 newUnderlyingDepositForAsset = userCurrentBalanceUnderlying -
      _amountToWithdrawUnderlying;
    uint256 currentTotalDebtUSD = _getUserTotalDebtUSD(msg.sender);
    if (currentTotalDebtUSD > 0) {
      //如果用户有借出，则需要计算健康因子
      uint256 newTotalCollateralEffectiveUSD = _calculateTotalCollateralEffectiveUSD_AfterWithdraw(
        msg.sender,
        _asset, // 发生变化的资产
        newUnderlyingDepositForAsset // 该资产变化后的底层余额
      );
      uint256 newHealthFactor = _calculateHealthFactor(
        newTotalCollateralEffectiveUSD,
        currentTotalDebtUSD
      );
      require(newHealthFactor >= MINIMUM_HEALTH_FACTOR, 'LendingPool: Health factor below minimum');
    }
    // --- 健康因子检查结束 ---

    // LendingPool 指示 aToken 销毁用户的 aToken
    // aToken.burn() 内部会根据当前的 liquidityIndex 计算需要 burn 的 scaled aToken 数量
    uint256 scaledAmountBurned = aToken.burn(
      msg.sender,
      _amountToWithdrawUnderlying,
      assetInfo.liquidityIndex
    );

    // 更新LendingPool中记录的总缩放存款
    assetInfo.totalScaledDeposits = aToken.getScaledTotalSupply(); //更新总抵押资产

    IERC20(_asset).safeTransfer(msg.sender, _amountToWithdrawUnderlying);
    emit Withdrawn(
      _asset,
      msg.sender,
      _amountToWithdrawUnderlying,
      scaledAmountBurned,
      block.timestamp
    );
  }

  function borrow(
    address _assetToBorrow,
    uint256 _amountToBorrowUnderlying
  ) external override nonReentrant {
    // 更新所有用户抵押品资产和要借资产的利息状态，以确保计算准确
    _updateUserAssetsState(msg.sender); // 更新用户所有相关的抵押品和已有借款的资产状态
    _updateState(_assetToBorrow); // 确保要借的资产状态也更新

    AssetData storage assetInfo = assetData[_assetToBorrow];
    require(assetInfo.isSupported, 'LendingPool: Asset not supported');
    require(_amountToBorrowUnderlying > 0, 'LendingPool: Amount must be > 0');

    // 计算用户总债务和借款能力
    uint256 totalDebtUSD = _getUserTotalDebtUSD(msg.sender);
    uint256 borrowingPowerUSD = _getUserBorrowPowerUSD(msg.sender);

    uint256 assetPrice = priceOracle.getAssetPrice(_assetToBorrow);
    require(assetPrice > 0, 'LendingPool: Asset price is 0, cannot borrow');
    uint256 amountToBorrowUSD = (_amountToBorrowUnderlying * assetPrice) /
      (10 ** assetInfo.decimals);

    require(
      totalDebtUSD + amountToBorrowUSD <= borrowingPowerUSD,
      'Borrow exceeds available credit'
    ); //借款超出可用信用额度

    uint256 currentTotalPoolActualDeposits = (assetInfo.totalScaledDeposits *
      assetInfo.liquidityIndex) / RAY;
    uint256 currentTotalPoolActualBorrows = (assetInfo.totalScaledVariableBorrows *
      assetInfo.variableBorrowIndex) / RAY;
    require(
      currentTotalPoolActualDeposits >= currentTotalPoolActualBorrows,
      'LendingPool: Inconsistent pool state'
    );

    uint256 availableLiquidity = currentTotalPoolActualDeposits - currentTotalPoolActualBorrows;
    require(
      availableLiquidity >= _amountToBorrowUnderlying,
      'LendingPool: Insufficient pool liquidity'
    );

    uint256 currentVariableBorrowIndex = assetInfo.variableBorrowIndex;
    uint256 scaledAmountToBorrow = (_amountToBorrowUnderlying * RAY) / currentVariableBorrowIndex;

    // Update state
    scaledUserBorrows[_assetToBorrow][msg.sender] += scaledAmountToBorrow;
    assetInfo.totalScaledVariableBorrows += scaledAmountToBorrow;

    // Transfer funds
    IERC20(_assetToBorrow).safeTransfer(msg.sender, _amountToBorrowUnderlying);

    emit Borrowed(
      _assetToBorrow,
      msg.sender,
      _amountToBorrowUnderlying,
      scaledAmountToBorrow,
      block.timestamp
    );
  }

  function repay(
    address _assetBorrowed,
    uint256 _amountToRepayUnderlying
  ) external override nonReentrant {
    _updateState(_assetBorrowed);
    AssetData storage assetInfo = assetData[_assetBorrowed];
    require(assetInfo.isSupported, 'LendingPool: Asset not supported');
    require(_amountToRepayUnderlying > 0, 'LendingPool: Repay amount must be > 0');

    uint256 currentVariableBorrowIndex = assetInfo.variableBorrowIndex;
    uint256 userScaledBorrow = scaledUserBorrows[_assetBorrowed][msg.sender];
    uint256 currentOwedWithInterestUnderlying = (userScaledBorrow * currentVariableBorrowIndex) /
      RAY;

    require(currentOwedWithInterestUnderlying > 0, 'LendingPool: No borrowings to repay');

    uint256 actualRepayAmountUnderlying = Math.min(
      _amountToRepayUnderlying,
      currentOwedWithInterestUnderlying
    );

    uint256 scaledAmountToRepay = (_amountToRepayUnderlying * RAY) / currentVariableBorrowIndex;

    // 对于非常小的 actualRepayAmountUnderlying 和很大的 currentVariableBorrowIndex，scaledAmountToRepay 可能会截断为0。
    // 需要确保 scaledAmountToRepay 至少能减少 userScaledBorrow。
    // Aave 的做法是，如果 scaledAmountToRepay 不足，且是最后一笔还款，直接将 userScaledBorrow 清零。

    if (
      actualRepayAmountUnderlying == currentOwedWithInterestUnderlying &&
      scaledAmountToRepay < userScaledBorrow
    ) {
      scaledAmountToRepay = userScaledBorrow; // 最后一笔还款，直接将 userScaledBorrow 清零。
    }

    scaledUserBorrows[_assetBorrowed][msg.sender] -= scaledAmountToRepay;
    assetInfo.totalScaledVariableBorrows -= scaledAmountToRepay;

    // Transfer funds from user to pool
    IERC20(_assetBorrowed).safeTransferFrom(msg.sender, address(this), actualRepayAmountUnderlying);

    emit Repaid(
      _assetBorrowed,
      msg.sender,
      msg.sender,
      actualRepayAmountUnderlying,
      scaledAmountToRepay,
      block.timestamp
    );
  }

  /**
   * @notice 执行清算操作。
   * @dev 清算者 (msg.sender) 帮助偿还 _userToLiquidate 的部分或全部 _debtAsset 债务，
   * 并以折扣价（通过liquidationBonus体现）获得 _userToLiquidate 的 _collateralAsset 作为回报。
   * @param _collateralAsset 被清算者用作抵押的资产，清算者希望获得的资产。
   * @param _debtAsset 被清算者需要偿还的债务资产。
   * @param _userToLiquidate 被清算用户的地址。
   * @param _debtToCoverInUnderlying 清算者希望为用户偿还的债务数量（以债务资产的底层单位表示）。
   * @param _receiveUnderlyingCollateral 对于Mini Aave简化版，我们假设此值总是true，清算者直接获得底层抵押品。
   */

  function liquidationCall(
    address _collateralAsset,
    address _debtAsset,
    address _userToLiquidate,
    uint256 _debtToCoverInUnderlying,
    bool _receiveUnderlyingCollateral //是否接收底层抵押品,简化版中忽略或要求为true
  ) external override nonReentrant {
    require(
      _receiveUnderlyingCollateral,
      'LendingPool: Only underlying collateral supported for now'
    );
    // --- 1. 更新相关资产的利息状态 ---
    // 更新被清算用户的所有相关资产状态，确保后续HF计算等基于最新数据
    _updateUserAssetsState(_userToLiquidate);
    // 单独更新本次清算直接涉及的债务资产和抵押品资产的状态（如果_updateUserAssetsState没覆盖或为了更精确）
    _updateState(_debtAsset);
    _updateState(_collateralAsset);

    AssetData storage debtAssetInfo = assetData[_debtAsset];
    AssetData storage collateralAssetInfo = assetData[_collateralAsset];

    require(collateralAssetInfo.isSupported, 'LendingPool: Collateral asset not supported');
    require(debtAssetInfo.isSupported, 'LendingPool: Debt asset not supported');
    require(_userToLiquidate != msg.sender, 'LendingPool: Can not liquidate self'); //不能自己给自己清算，否则清算者可以无限清算

    // --- 2. 检查健康因子 ---
    uint256 totalCollateralEffectiveUSD = _calculateUserTotalCollateralEffectiveUSD(
      _userToLiquidate
    );
    uint256 totalDebtUSD = _getUserTotalDebtUSD(_userToLiquidate);
    uint256 userHealthFactor = _calculateHealthFactor(totalCollateralEffectiveUSD, totalDebtUSD);
    require(
      userHealthFactor < MINIMUM_HEALTH_FACTOR,
      'LendingPool: Position cannot be liquidated (HF healthy)'
    );

    // --- 3. 验证和确定实际要偿还的债务数量 ---
    uint256 userEffectiveDebtForAsset = getEffectiveUserBorrowBalance(_debtAsset, _userToLiquidate);
    require(
      userEffectiveDebtForAsset > 0,
      'LendingPool: User has no debt of specified asset to liquidate '
    );

    // 清算者偿还的金额不能超过用户所欠的金额（或超过用户所选清算上限的一半，Aave有此逻辑，在此简化）
    // Aave V2允许最多清算掉用户总债务的50% (CLOSE_FACTOR_HF_THRESHOLD)，我们这里先允许清算者指定数量，但不超过总额。
    uint256 actualDebtToCover = Math.min(_debtToCoverInUnderlying, userEffectiveDebtForAsset);
    // Aave V2还有一个 closeFactor，通常是0.5，表示一次最多清算一半的债务。
    // uint256 maxDebtToLiquidate = (userEffectiveDebtForAsset * MAX_LIQUIDATION_CLOSE_FACTOR_BPS) / PERCENTAGE_FACTOR;
    // actualDebtToCover = Math.min(actualDebtToCover, maxDebtToLiquidate);
    require(actualDebtToCover > 0, 'LendingPool: Debt to cover cannot be zero');

    // --- 4. 计算清算者应获得的抵押品数量 ---
    uint256 debtAssetPriceUSD = priceOracle.getAssetPrice(_debtAsset);
    uint256 collateralAssetPriceUSD = priceOracle.getAssetPrice(_collateralAsset);
    //此时的价格带有ORACLE_PRICE_DECIMALS
    require(
      debtAssetPriceUSD > 0 && collateralAssetPriceUSD > 0,
      'LendingPool: Oracle price invalid for liquidation'
    );

    // 将要偿还的债务价值转换为USD (结果带 ORACLE_PRICE_DECIMALS)
    uint256 debtToCoverValueUSD = (actualDebtToCover * debtAssetPriceUSD) /
      (10 ** debtAssetInfo.decimals);

    // 计算清算者应获得的抵押品总价值USD (包含清算奖励)
    // liquidationBonus 假如是500（代表5%）
    uint256 collateralToReceiveValueUSD = (debtToCoverValueUSD *
      (PERCENTAGE_FACTOR + collateralAssetInfo.liquidationBonus)) / PERCENTAGE_FACTOR;

    // 将应获得的抵押品总价值USD转换回抵押品资产价值
    uint256 amountOfCollateralToSeizeUnderlying = (collateralToReceiveValueUSD *
      (10 ** collateralAssetInfo.decimals)) / collateralAssetPriceUSD;

    // --- 5. 检查被清算用户是否有足够的指定抵押品 ---
    uint256 userEffectiveCollateralBalance = getEffectiveUserDeposit(
      _collateralAsset,
      _userToLiquidate
    );
    require(
      userEffectiveCollateralBalance >= amountOfCollateralToSeizeUnderlying,
      'LendingPool: Not enough user collateral to seize for liquidation'
    );
    // 如果这里允许部分清算（即抵押品不足以支付全部的amountOfCollateralToSeizeUnderlying），逻辑会更复杂。
    // 当前简化：如果抵押品不足以覆盖计算出的 seizing amount，则revert。清算者应选择更小的_debtToCover。

    // --- 6. 从清算者处接收债务资产，减少被清算用户债务 ---
    IERC20(_debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtToCover);

    uint256 scaledDebtReduced = (actualDebtToCover * RAY) / debtAssetInfo.variableBorrowIndex;
    //安全检查：确保 scaledDebtReduced 不超过当前 scaled 借款
    scaledDebtReduced = Math.min(
      scaledDebtReduced,
      scaledUserBorrows[_debtAsset][_userToLiquidate]
    );

    scaledUserBorrows[_debtAsset][_userToLiquidate] -= scaledDebtReduced;
    debtAssetInfo.totalScaledVariableBorrows -= scaledDebtReduced;
    // 注意：这里偿还的 debt asset 会增加池子的 availableLiquidity，可能会影响后续的利率计算。
    // 同时，这部分还款也应被视为池子的收入（因为它减少了总借款），影响准备金和存款利息。
    // _updateState 中处理 reserveFactor 的部分基于总借款利息，还款本身不直接产生新准备金，而是减少了产生准备金的基数。

    // --- 7. 将抵押品资产转移给清算者，减少被清算用户抵押 ---
    uint256 scaledCollateralSeized = (amountOfCollateralToSeizeUnderlying * RAY) /
      collateralAssetInfo.liquidityIndex;
    // 安全检查
    scaledCollateralSeized = Math.min(
      scaledCollateralSeized,
      scaledUserDeposits[_collateralAsset][_userToLiquidate]
    );

    scaledUserDeposits[_collateralAsset][_userToLiquidate] -= scaledCollateralSeized;
    collateralAssetInfo.totalScaledDeposits -= scaledCollateralSeized;

    IERC20(_collateralAsset).safeTransfer(msg.sender, amountOfCollateralToSeizeUnderlying);

    // --- 8. 发出事件 ---
    emit LiquidationCall(
      _collateralAsset,
      _debtAsset,
      _userToLiquidate,
      actualDebtToCover,
      amountOfCollateralToSeizeUnderlying,
      msg.sender, // liquidator
      true, // _receiveUnderlyingCollateral, // true in our case
      block.timestamp
    );
  }

  /**
   * @inheritdoc ILendingPool
   * @dev 执行闪电贷。
   * 1. 检查参数和流动性。
   * 2. 计算手续费。
   * 3. 更新资产状态（如果闪电贷的资金也参与生息，通常闪电贷的资金被视为短期移出，不影响整体利息计算的资金基数，但手续费会增加储备）。
   * 4. 将资金转给接收者。
   * 5. 调用接收者的 executeOperation 函数。
   * 6. 验证接收者是否归还了本金+手续费。
   * 7. 如果成功，将手续费加入准备金。如果失败，整个交易回滚。
   */

  function flashLoan(
    address _receiverAddress,
    address _asset,
    uint256 _amount,
    bytes calldata _params
  ) external override nonReentrant {
    // 1. 检查参数和流动性
    AssetData storage assetInfo = assetData[_asset];
    require(assetInfo.isSupported, 'LendingPool: Asset not supported');
    require(_amount > 0, 'LendingPool: Amount must be > 0');
    require(
      _receiverAddress != address(0) && _receiverAddress != address(this),
      'LendingPool: Invalid receiver address'
    );

    // 在Aave中，闪电贷的资金通常被认为是"暂时不可用"但不影响整体池子的计息基数（totalScaledDeposits）。
    // 因此，_updateState(_asset) 可以在操作前后都调用，或者在操作后调用以累积手续费产生的收益。
    // 为简单起见，我们可以在最后将手续费直接加入储备。
    // 利息模型通常不考虑在途的闪电贷资金。

    // 检查是否有足够的流动性 (不考虑该笔闪电贷本身)
    uint256 availableLiquidityBeforeFlashLoan = (assetInfo.totalScaledDeposits *
      assetInfo.liquidityIndex) /
      RAY -
      (assetInfo.totalScaledVariableBorrows * assetInfo.variableBorrowIndex) /
      RAY;
    require(
      availableLiquidityBeforeFlashLoan >= _amount,
      'LendingPool: Not enough liquidity for flash loan'
    );

    // 计算手续费
    uint256 fee = (_amount * FLASHLOAN_FEE_BASIS_POINTS) / PERCENTAGE_FACTOR;
    require(
      fee > 0,
      'LendingPool: Flash loan fee cannot be zero (amount too small or fee too low)'
    );
    uint256 amountToRepay = _amount + fee;

    // 1. 将资金转给接受者
    IERC20(_asset).safeTransfer(_receiverAddress, _amount);

    // 2. 调用接收者的executeOperation函数
    // msg.sender 是发起 flashLoan 调用的用户/合约
    // address(this) 是 LendingPool 合约地址
    bool success = IFlashLoanReceiver(_receiverAddress).executeOperation(
      msg.sender, // initiator of the flashloan
      _asset,
      _amount,
      fee,
      _params
    );
    require(success, 'LendingPool: Flash loan receiver executed operation unsuccessfully');

    // 在 executeOperation 之后，接收者应已将 amountToRepay 转回。
    // LendingPool 现在从自身（池子）处提取手续费并将其加入储备金。
    // 底层资产 _asset 的代币现在应该已经回到 LendingPool。
    // 我们需要确保接收者已经将 _amount + fee 转回。
    // IFlashLoanReceiver 的实现者有责任确保这一点。

    // 从用户处（即_receiverAddress，或者如果指定了不同的付款人）安全地将本金+手续费转回本合约
    // 这要求 _receiverAddress (或 executeOperation 内部的逻辑) 已经 approve 了本合约
    // 3. 验证资金是否归还 (本金 + 手续费)
    IERC20(_asset).safeTransferFrom(_receiverAddress, address(this), amountToRepay);

    // 4. 手续费加入准备金 (在确认资金已全部归还后)
    // _updateState 会在下次相关资产操作时更新指数，此时增加的储备会间接使存款人受益
    // （因为更多的总储备可能意味着未来可以降低 reserveFactor 或利率模型的参数向存款人倾斜）
    // 或者，手续费的收益可以使 liquidityIndex 增长更快一点点，但这需要修改 _updateState 逻辑。
    // Aave V2/V3 的做法是将闪电贷手续费累积到储备中。
    _updateState(_asset); // 更新状态以反映当前池内资金情况（虽然主要指数变化不大，但时间戳应更新）
    assetData[_asset].currentTotalReserves += fee; // 直接将手续费加入该资产的准备金

    emit FlashLoan(_receiverAddress, msg.sender, _asset, _amount, fee, block.timestamp);
  }

  // --- Helper: update user's asset state ---
  function _updateUserAssetsState(address _user) internal {
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address asset = supportedAssetsList[i];
      if (scaledUserDeposits[asset][_user] > 0 || scaledUserBorrows[asset][_user] > 0) {
        _updateState(asset);
      }
    }
  }

  // --- External view functions ---

  function getFlashLoanFeePercentage() external pure override returns (uint256) {
    return FLASHLOAN_FEE_BASIS_POINTS;
  }

  function getEffectiveUserDeposit(address _asset, address _user) public view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    if (assetInfo.aTokenAddress == address(0)) {
      return 0;
    }
    uint256 scaledBalance = AToken(assetInfo.aTokenAddress).scaledBalanceOf(_user);
    return (scaledBalance * assetInfo.liquidityIndex) / RAY;
  }

  function getScaledUserDeposit(address _asset, address _user) external view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    if (assetInfo.aTokenAddress == address(0)) return 0;
    return AToken(assetInfo.aTokenAddress).scaledBalanceOf(_user);
  }

  function getEffectiveUserBorrowBalance(
    address _asset,
    address _user
  ) public view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    return (scaledUserBorrows[_asset][_user] * assetInfo.variableBorrowIndex) / RAY;
  }

  function getScaledUserBorrowBalance(
    address _asset,
    address _user
  ) external view returns (uint256) {
    return scaledUserBorrows[_asset][_user];
  }

  function getCurrentTotalActualDeposits(address _asset) external view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    if (assetInfo.aTokenAddress == address(0)) return 0;
    return
      (AToken(assetInfo.aTokenAddress).getScaledTotalSupply() * assetInfo.liquidityIndex) / RAY;
  }

  function getCurrentTotalActualBorrows(address _asset) external view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    return (assetInfo.totalScaledVariableBorrows * assetInfo.variableBorrowIndex) / RAY;
  }

  function getPriceOracle() external view override returns (address) {
    return address(priceOracle);
  }

  function getAssetData(
    address _asset
  ) external view override returns (AssetDataReturn memory assetDataReturn) {
    AssetData storage assetInfo = assetData[_asset];
    uint256 fetchedAnnualLiquidityRateRAY = 0;
    uint256 fetchedAnnualVariableBorrowRateRAY = 0;
    if (assetInfo.isSupported && address(assetInfo.interestRateStrategy) != address(0)) {
      IInterestRateStrategy strategy = IInterestRateStrategy(assetInfo.interestRateStrategy);
      RateCalculationParams memory params = RateCalculationParams({
        totalDeposits: _getCurrentTotalDeposits(_asset), // 你需要有这些辅助 internal view 函数
        totalBorrows: _getCurrentTotalBorrows(_asset), // 你需要有这些辅助 internal view 函数
        totalReserves: assetInfo.currentTotalReserves,
        availableLiquidity: _getCurrentTotalDeposits(_asset) - _getCurrentTotalBorrows(_asset),
        reserveFactorBps: assetInfo.reserveFactor
      });
      (fetchedAnnualLiquidityRateRAY, fetchedAnnualVariableBorrowRateRAY) = strategy
        .calculateInterestRates(params);
    }
    return
      AssetDataReturn({
        isSupported: assetInfo.isSupported,
        decimals: assetInfo.decimals,
        ltv: assetInfo.ltv,
        liquidationThreshold: assetInfo.liquidationThreshold,
        interestRateStrategy: assetInfo.interestRateStrategy,
        reserveFactor: assetInfo.reserveFactor,
        liquidationBonus: assetInfo.liquidationBonus,
        liquidityIndex: assetInfo.liquidityIndex,
        variableBorrowIndex: assetInfo.variableBorrowIndex,
        lastUpdateTimestamp: assetInfo.lastUpdateTimestamp,
        totalScaledDeposits: assetInfo.totalScaledDeposits,
        totalScaledVariableBorrows: assetInfo.totalScaledVariableBorrows,
        currentTotalReserves: assetInfo.currentTotalReserves,
        aTokenAddress: assetInfo.aTokenAddress,
        currentAnnualLiquidityRateRAY: fetchedAnnualLiquidityRateRAY,
        currentAnnualVariableBorrowRateRAY: fetchedAnnualVariableBorrowRateRAY
      });
  }

  function getAssetPrice(address _asset) public view override returns (uint256) {
    return priceOracle.getAssetPrice(_asset);
  }

  function getSupportedAssets() external view override returns (address[] memory) {
    return supportedAssetsList;
  }

  // --- New External View functions for Phase 3 ---
  // Internal helpers for USD calculations, now using effective balances
  function getUserTotalCollateralUSD(
    address _user
  ) external view override returns (uint256 totalCollateralUSDVal) {
    return _getUserTotalCollateralUSD(_user);
  }

  function getUserTotalDebtUSD(
    address _user
  ) external view override returns (uint256 totalDebtUSDVal) {
    return _getUserTotalDebtUSD(_user);
  }

  function getUserBorrowPowerUSD(
    address _user
  ) external view override returns (uint256 totalBorrowingPowerUSDVal) {
    return _getUserBorrowPowerUSD(_user);
  }

  function getUserAvailableBorrowsUSD(
    address _user
  ) external view override returns (uint256 availableBorrowsUSDVal) {
    uint256 borrowingPower = _getUserBorrowPowerUSD(_user);
    uint256 totalDebt = _getUserTotalDebtUSD(_user);
    if (borrowingPower > totalDebt) {
      return borrowingPower - totalDebt;
    }
    return 0;
  }

  function calculateHealthFactor(
    address _user
  ) external view override returns (uint256 healthFactorVal) {
    uint256 totalCollateralEffectiveUSD = _calculateUserTotalCollateralEffectiveUSD(_user);
    uint256 totalDebt = _getUserTotalDebtUSD(_user);
    healthFactorVal = _calculateHealthFactor(totalCollateralEffectiveUSD, totalDebt);
    return healthFactorVal;
  }

  // --- Internal Helper Functions for Calculations (Phase 3) ---
  // Internal helpers for USD calculations, now using effective balances
  function _getUserTotalCollateralUSD(
    address _user
  ) internal view returns (uint256 totalCollateralUSD) {
    totalCollateralUSD = 0;
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address asset = supportedAssetsList[i];
      uint256 effectiveUserDepositAmount = getEffectiveUserDeposit(asset, _user);
      if (effectiveUserDepositAmount > 0) {
        AssetData storage assetInfo = assetData[asset];
        if (assetInfo.decimals == 0) continue;
        uint256 assetPrice = priceOracle.getAssetPrice(asset);
        if (assetPrice > 0) {
          totalCollateralUSD +=
            (effectiveUserDepositAmount * assetPrice) /
            (10 ** assetInfo.decimals);
        }
      }
    }
    return totalCollateralUSD;
  }

  function _getUserTotalDebtUSD(address _user) internal view returns (uint256 totalDebtUSD) {
    totalDebtUSD = 0;
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address asset = supportedAssetsList[i];
      uint256 effectiveUserBorrowAmount = getEffectiveUserBorrowBalance(asset, _user);
      if (effectiveUserBorrowAmount > 0) {
        AssetData storage assetInfo = assetData[asset];
        if (assetInfo.decimals == 0) continue;
        uint256 assetPrice = priceOracle.getAssetPrice(asset);
        if (assetPrice > 0) {
          totalDebtUSD += (effectiveUserBorrowAmount * assetPrice) / (10 ** assetInfo.decimals);
        }
      }
    }
    return totalDebtUSD;
  }

  function _getUserBorrowPowerUSD(
    address _user
  ) internal view returns (uint256 totalBorrowingPowerUSD) {
    totalBorrowingPowerUSD = 0;
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address asset = supportedAssetsList[i];
      uint256 effectiveUserDepositAmount = getEffectiveUserDeposit(asset, _user);

      if (effectiveUserDepositAmount > 0) {
        AssetData storage assetInfo = assetData[asset];
        if (assetInfo.decimals == 0 || assetInfo.ltv == 0) continue;
        uint256 assetPrice = priceOracle.getAssetPrice(asset);
        if (assetPrice > 0) {
          uint256 collateralValueUSD = (effectiveUserDepositAmount * assetPrice) /
            (10 ** assetInfo.decimals);
          totalBorrowingPowerUSD += (collateralValueUSD * assetInfo.ltv) / PERCENTAGE_FACTOR;
          //因为ltv是百分比,用7500表示75%，所以需要除以PERCENTAGE_FACTOR
        }
      }
    }
    return totalBorrowingPowerUSD;
  }

  //计算用户总抵押资产的有效美元价值(也就是最大可借出资产价值=抵押资产价值*清算阈值/百分比)
  function _calculateUserTotalCollateralEffectiveUSD(
    address _user
  ) internal view returns (uint256 totalCollateralEffectiveUSD) {
    totalCollateralEffectiveUSD = 0;
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address asset = supportedAssetsList[i];
      uint256 effectiveUserDepositAmount = getEffectiveUserDeposit(asset, _user);
      if (effectiveUserDepositAmount > 0) {
        AssetData storage assetInfo = assetData[asset];
        if (assetInfo.decimals == 0 || assetInfo.liquidationThreshold == 0) continue;
        uint256 assetPrice = priceOracle.getAssetPrice(asset);
        if (assetPrice > 0) {
          uint256 collateralValueUSD = (effectiveUserDepositAmount * assetPrice) /
            (10 ** assetInfo.decimals);
          totalCollateralEffectiveUSD +=
            (collateralValueUSD * assetInfo.liquidationThreshold) /
            PERCENTAGE_FACTOR;
        }
      }
    }
    return totalCollateralEffectiveUSD;
  }

  //Helper for withdraw check: calculates effective collateral if a specific asset's deposit changes
  // bool _isDepositIncrease  还可以加一个参数来表明存款是否增长，但不是严格要求的，如果直接传递最终的数额也行。
  function _calculateTotalCollateralEffectiveUSD_AfterWithdraw(
    address _user,
    address _changedAsset,
    uint256 _newUnderlyingDepositAmountForChangedAsset
  ) internal view returns (uint256 totalCollateralEffectiveUSD) {
    totalCollateralEffectiveUSD = 0;
    for (uint256 i = 0; i < supportedAssetsList.length; i++) {
      address currentAsset = supportedAssetsList[i];
      uint256 effectiveUserDepositAmount;

      if (currentAsset == _changedAsset) {
        effectiveUserDepositAmount = _newUnderlyingDepositAmountForChangedAsset;
      } else {
        effectiveUserDepositAmount = getEffectiveUserDeposit(currentAsset, _user);
      }

      if (effectiveUserDepositAmount > 0) {
        AssetData storage assetInfo = assetData[currentAsset];
        if (assetInfo.decimals == 0 || assetInfo.liquidationThreshold == 0) continue;
        uint256 assetPrice = priceOracle.getAssetPrice(currentAsset);
        if (assetPrice > 0) {
          uint256 collateralValueUSD = (effectiveUserDepositAmount * assetPrice) /
            (10 ** assetInfo.decimals);
          totalCollateralEffectiveUSD +=
            (collateralValueUSD * assetInfo.liquidationThreshold) /
            PERCENTAGE_FACTOR;
        }
      }
    }
  }

  function _calculateHealthFactor(
    uint256 _totalCollateralEffectiveUSD,
    uint256 _totalDebtUSD
  ) internal pure returns (uint256 healthFactor) {
    if (_totalDebtUSD == 0) {
      healthFactor = type(uint256).max;
    } else {
      healthFactor = (_totalCollateralEffectiveUSD * HEALTH_FACTOR_PRECISION) / _totalDebtUSD;
      //HEALTH_FACTOR_PRECISION = 10**18
      //先乘以精度，再做除法。因为在solidity中整数除法会默认截断小数部分
      //等之后使用他的时候，看情况再除以精度。
    }
  }

  // --- Internal Helper Functions for Calculations (Phase 4) ---
  function _getCurrentTotalDeposits(address _asset) internal view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    if (assetInfo.aTokenAddress == address(0)) return 0; // 如果没有aToken，则没有存款
    // totalScaledDeposits 现在应该由 aToken 的 getScaledTotalSupply() 来体现
    // 麻烦一点的办法是在 LendingPool 的 assetInfo 中维护一个 totalScaledDeposits，并在 mint/burn 时更新它
    // 这里简化，并且为了与 aToken 的 totalSupply 同步，可以这样做：
    return
      (AToken(assetInfo.aTokenAddress).getScaledTotalSupply() * assetInfo.liquidityIndex) / RAY;
  }

  function _getCurrentTotalBorrows(address _asset) internal view returns (uint256) {
    AssetData storage assetInfo = assetData[_asset];
    return (assetInfo.totalScaledVariableBorrows * assetInfo.variableBorrowIndex) / RAY;
  }

  /**
   * @notice 内部函数，更新指定资产的利息状态和指数
   * @dev 这个函数会在每次与资产相关的核心操作（存、取、借、还）之前被调用。
   * 它的主要目的是计算自上次更新以来累积的利息，并相应地更新资产的
   * liquidityIndex (存款指数) 和 variableBorrowIndex (借款指数)，
   * 同时也会更新协议的准备金。
   * @param _asset 要更新状态的资产地址
   */
  function _updateState(address _asset) internal {
    AssetData storage assetInfo = assetData[_asset];
    // 如果资产当前未激活或时间未流逝，则不更新。
    if (!assetInfo.isSupported || block.timestamp == assetInfo.lastUpdateTimestamp) {
      return;
    }

    uint256 timeDelta = block.timestamp - assetInfo.lastUpdateTimestamp;
    assetInfo.lastUpdateTimestamp = block.timestamp;

    // 如果没有存款或借款，指数不会因利率而改变（但时间戳已更新）
    if (assetInfo.totalScaledDeposits == 0 && assetInfo.totalScaledVariableBorrows == 0) {
      return;
    }

    // --- 2. 获取当前利率 ---
    // 获取此资产配置的利率策略合约实例
    IInterestRateStrategy strategy = IInterestRateStrategy(assetInfo.interestRateStrategy);
    // 确保利率策略地址已设置
    require(address(strategy) != address(0), 'LendingPool: Interest strategy not set');

    // 准备调用利率策略合约所需的参数
    RateCalculationParams memory params = RateCalculationParams({
      totalDeposits: _getCurrentTotalDeposits(_asset),
      totalBorrows: _getCurrentTotalBorrows(_asset),
      totalReserves: assetInfo.currentTotalReserves,
      availableLiquidity: _getCurrentTotalDeposits(_asset) - _getCurrentTotalBorrows(_asset),
      reserveFactorBps: assetInfo.reserveFactor
    });

    (uint256 annualLiquidityRateRAY, uint256 annualVariableBorrowRateRAY) = strategy
      .calculateInterestRates(params);

    // 将年化利率转换为每秒利率
    uint256 liquidityRatePerSecondRAY = annualLiquidityRateRAY / SECONDS_PER_YEAR_FOR_RATES;
    uint256 variableBorrowRatePerSecondRAY = annualVariableBorrowRateRAY /
      SECONDS_PER_YEAR_FOR_RATES;

    // --- 3. 更新存款指数 (Liquidity Index) 和准备金 (Reserves) ---
    // 只有当池中有存款时（即总缩放存款 > 0），存款利息才有意义，指数才需要增长。
    if (assetInfo.totalScaledDeposits > 0) {
      // 计算在 timeDelta 时间内，由 currentLiquidityRatePerSecondRAY 产生的复利增长因子部分。
      //(rate_per_second_ray * time_delta) 是总的线性累积利率（RAY单位）
      // Aave V2 使用线性近似： newIndex = oldIndex * (1 + rate * timeDelta)
      // 用RAY数学表示: newIndex = oldIndex * (RAY + (rate_RAY * timeDelta)) / RAY

      uint256 compoundedLiquidityInterestFactorPart = (liquidityRatePerSecondRAY * timeDelta);
      assetInfo.liquidityIndex =
        (assetInfo.liquidityIndex * (RAY + compoundedLiquidityInterestFactorPart)) /
        RAY;
    }

    // --- 4. 更新借款指数 (Variable Borrow Index) 和准备金 (Reserves) ---
    // 只有当池中有借款时（即总缩放借款 > 0），借款利息才有意义，指数才需要增长。
    if (assetInfo.totalScaledVariableBorrows > 0) {
      uint256 oldVariableBorrowIndex = assetInfo.variableBorrowIndex;
      uint256 compoundedBorrowInterestFactorPart = (variableBorrowRatePerSecondRAY * timeDelta);
      assetInfo.variableBorrowIndex =
        (assetInfo.variableBorrowIndex * (RAY + compoundedBorrowInterestFactorPart)) /
        RAY;

      // 计算本期新增的总借款利息 (以底层资产单位计量)
      if (assetInfo.variableBorrowIndex > oldVariableBorrowIndex) {
        // 确保指数增长了
        //totalAccruedBorrowInterestUnderlying 新增的总借款利息
        uint256 totalAccruedBorrowInterestUnderlying = (assetInfo.totalScaledVariableBorrows *
          (assetInfo.variableBorrowIndex - oldVariableBorrowIndex)) / RAY;

        if (totalAccruedBorrowInterestUnderlying > 0) {
          uint256 reserveAmountToAdd = (totalAccruedBorrowInterestUnderlying *
            assetInfo.reserveFactor) / PERCENTAGE_FACTOR;
          assetInfo.currentTotalReserves += reserveAmountToAdd;
          emit ReservesCollected(_asset, address(this), reserveAmountToAdd); // address(this) or a designated collector
        }
      }
    }
  }

  // --- External functions callable by Configurator ---
  function configureAsset(
    address _asset,
    bool _isSupported,
    uint8 _assetDecimals,
    uint256 _ltv,
    uint256 _liquidationThreshold,
    address _interestRateStrategy,
    uint256 _reserveFactor,
    uint256 _liquidationBonus
  ) external override onlyConfigurator {
    require(_asset != address(0), 'LendingPool: Invalid asset address');
    if (_isSupported) {
      require(_interestRateStrategy != address(0), 'LendingPool: Interest strategy not set');
      require(_reserveFactor <= PERCENTAGE_FACTOR, 'LendingPool: Reserve factor must be <= 100%');
      require(_ltv < PERCENTAGE_FACTOR && _ltv > 0, 'LendingPool: LTV must be > 0 and <= 100%');
      require(
        _liquidationThreshold > _ltv && _liquidationThreshold < PERCENTAGE_FACTOR,
        'LendingPool: Liquidation threshold must be > LTV and <= 100%'
      );
      require(
        _assetDecimals > 0 && _assetDecimals <= 36,
        'LendingPool: Asset decimals must be > 0 and <= 36'
      );
      require(
        _liquidationBonus < PERCENTAGE_FACTOR / 2,
        'LendingPool: Liquidation bonus must be < 50%'
      );
    }

    AssetData storage assetInfo = assetData[_asset];
    bool oldSupported = assetInfo.isSupported; //之前的配置状态
    assetInfo.isSupported = _isSupported; //现在的配置状态
    assetInfo.decimals = _assetDecimals;
    assetInfo.ltv = _ltv;
    assetInfo.liquidationThreshold = _liquidationThreshold;
    assetInfo.interestRateStrategy = _interestRateStrategy;
    assetInfo.reserveFactor = _reserveFactor;
    assetInfo.liquidationBonus = _liquidationBonus;

    if (_isSupported && !oldSupported) {
      //如果现在的支持状态为True，之前的支持状态为False，说明是新加入的资产
      assetInfo.lastUpdateTimestamp = block.timestamp;
      assetInfo.liquidityIndex = RAY;
      assetInfo.variableBorrowIndex = RAY;
      assetInfo.totalScaledDeposits = 0;
      assetInfo.totalScaledVariableBorrows = 0;
      assetInfo.currentTotalReserves = 0;
      //example name and symbol
      string memory aTokenName = string(
        abi.encodePacked('MiniAave Interest Bearing', IERC20Metadata(_asset).symbol())
      );
      string memory aTokenSymbol = string(abi.encodePacked('ma', IERC20Metadata(_asset).symbol()));

      AToken newAToken = new AToken(
        address(this), // LendingPool address
        _asset, //Underlying asset address
        aTokenName,
        aTokenSymbol // AToken decimals match underlying
      );
      assetInfo.aTokenAddress = address(newAToken);
      require(supportedAssetIndex[_asset] == 0, 'LendingPool: Asset already in list');
      supportedAssetsList.push(_asset);
      supportedAssetIndex[_asset] = supportedAssetsList.length; // Store index + 1
    } else if (!_isSupported && oldSupported) {
      //如果之前支持，现在不支持，说明移出去了
      // Removing asset from supportedAssetsList
      uint256 assetIdxMapping = supportedAssetIndex[_asset];
      require(assetIdxMapping > 0, 'LendingPool: Asset not in list for removal');
      uint256 assetActualIdx = assetIdxMapping - 1;

      if (assetActualIdx < supportedAssetsList.length - 1) {
        // If not the last element
        address lastAsset = supportedAssetsList[supportedAssetsList.length - 1];
        supportedAssetsList[assetActualIdx] = lastAsset;
        supportedAssetIndex[lastAsset] = assetActualIdx + 1;
      }
      supportedAssetsList.pop();
      supportedAssetIndex[_asset] = 0;
      assetInfo.aTokenAddress = address(0); // 清除 aToken 地址
      // Note: 这只是简易模型，真实的协议有更复杂的下架移除程序。
    }

    // 这里不加入aToken是因为把它当作内部的信息，不在这里触发
    emit AssetConfigured(
      _asset,
      _isSupported,
      _assetDecimals,
      _ltv,
      _liquidationThreshold,
      _interestRateStrategy,
      _reserveFactor,
      _liquidationBonus
    );
  }

  function setAssetInterestRateStrategy(
    address _asset,
    address _newStrategyAddress
  ) external override onlyConfigurator {
    require(assetData[_asset].isSupported, 'LendingPool: Asset not supported');
    require(_newStrategyAddress != address(0), 'LendingPool: Invalid new IR strategy address');
    _updateState(_asset);
    assetData[_asset].interestRateStrategy = _newStrategyAddress;
    emit InterestRateStrategyUpdated(_asset, _newStrategyAddress);
  }

  function setAssetReserveFactor(
    address _asset,
    uint256 _newReserveFactor
  ) external onlyConfigurator {
    require(assetData[_asset].isSupported, 'LendingPool: Asset not supported');
    require(_newReserveFactor < PERCENTAGE_FACTOR, 'LendingPool: New reserve factor too high');
    _updateState(_asset);
    assetData[_asset].reserveFactor = _newReserveFactor;
    emit ReserveFactorUpdated(_asset, _newReserveFactor);
  }

  function setAssetLiquidationBonus(
    address _asset,
    uint256 _newLiquidationBonus
  ) external override onlyConfigurator {
    require(assetData[_asset].isSupported, 'LendingPool: Asset not supported');
    require(
      _newLiquidationBonus < PERCENTAGE_FACTOR / 2,
      'LendingPool: Liquidation bonus too high'
    );
    assetData[_asset].liquidationBonus = _newLiquidationBonus;
  }
}
