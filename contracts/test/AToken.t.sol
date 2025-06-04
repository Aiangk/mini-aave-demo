// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from 'forge-std/Test.sol';
import {AToken} from '../src/Tokens/AToken.sol';
import {ILendingPool} from '../src/Interfaces/ILendingPool.sol';

contract ATokenTest is Test {
  // 测试 aToken 的基本 ERC20 功能（transfer, approve, transferFrom），这些操作的是缩放余额。
  // 测试 balanceOf() 和 totalSupply() 是否能正确返回计息后的底层资产数量（需要配合 mock 的 LendingPool 提供 liquidityIndex）。
  // 测试 mint() 和 burn()：
  // 只能由 LendingPool 调用。
  // 传入底层资产数量，内部正确转换为缩放单位进行存储。
  // scaledBalanceOf 和 getScaledTotalSupply 返回正确的缩放值。
  address constant MOCK_LENDING_POOL = address(0x1234);
  address constant MOCK_UNDERLYING = address(0x5678);
  address constant USER1 = address(0x9999);
  address constant USER2 = address(0x8888);

  uint256 constant RAY = 1e27;
  uint8 constant DECIMALS = 18;
  uint256 constant INITIAL_LIQUIDITY_INDEX = RAY;

  AToken aToken;

  function setUp() public {
    // 部署 aToken
    aToken = new AToken(MOCK_LENDING_POOL, MOCK_UNDERLYING, 'Test AToken', 'aTest');

    // 模拟 LendingPool 身份
    vm.startPrank(MOCK_LENDING_POOL);

    // 为用户铸造一些初始代币
    aToken.mint(USER1, 1000e18, INITIAL_LIQUIDITY_INDEX);
    aToken.mint(USER2, 1000e18, INITIAL_LIQUIDITY_INDEX);

    vm.stopPrank();
  }

  // 测试基本的 ERC20 功能
  function test_Transfer() public {
    vm.startPrank(USER1);
    uint256 amount = 100e18; // 这个 amount 代表的是 scaled amount，因为 transfer 直接操作存储的余额

    uint256 user1BalanceBefore = aToken.scaledBalanceOf(USER1);
    uint256 user2BalanceBefore = aToken.scaledBalanceOf(USER2);

    aToken.transfer(USER2, amount);

    uint256 user1BalanceAfter = aToken.scaledBalanceOf(USER1);
    uint256 user2BalanceAfter = aToken.scaledBalanceOf(USER2);

    assertEq(user1BalanceAfter, user1BalanceBefore - amount);
    assertEq(user2BalanceAfter, user2BalanceBefore + amount);
    vm.stopPrank();
  }

  function test_ApproveAndTransferFrom() public {
    vm.startPrank(USER1);
    uint256 amount = 100e18;
    aToken.approve(USER2, amount);
    vm.stopPrank();

    vm.startPrank(USER2);
    uint256 user1BalanceBefore = aToken.scaledBalanceOf(USER1);
    uint256 user2BalanceBefore = aToken.scaledBalanceOf(USER2);

    aToken.transferFrom(USER1, USER2, amount);

    uint256 user1BalanceAfter = aToken.scaledBalanceOf(USER1);
    uint256 user2BalanceAfter = aToken.scaledBalanceOf(USER2);

    assertEq(user1BalanceAfter, user1BalanceBefore - amount);
    assertEq(user2BalanceAfter, user2BalanceBefore + amount);
    vm.stopPrank();
  }

  // 测试计息功能
  function test_BalanceOfWithInterest() public {
    // USER1 的初始 scaledBalance 是 1000e18 (因为 setup 时 mint 了 1000e18 underlying, index 是 RAY)
    uint256 depositAmount = 1000e18;
    uint256 newLiquidityIndex = 2 * RAY; // 利息使指数翻倍

    // 关键：模拟 LendingPool 的 getAssetData 函数的返回值
    bool mock_isSupported = true;
    uint8 mock_decimals = DECIMALS; // 使用与aToken相同的decimals
    uint256 mock_ltv = 0;
    uint256 mock_liquidationThreshold = 0;
    address mock_irStrategy = address(0);
    uint256 mock_reserveFactor = 0;
    uint256 mock_liquidationBonus = 0;

    // uint256 liquidityIndex IS newLiquidityIndex
    uint256 mock_variableBorrowIndex = RAY;
    uint256 mock_lastUpdateTimestamp = block.timestamp; // 当前时间戳
    uint256 mock_totalScaledDeposits = aToken.getScaledTotalSupply(); // 可以用当前的scaled total supply
    uint256 mock_totalScaledVariableBorrows = 0;
    uint256 mock_totalReserves = 0;
    address mock_aTokenAddress = address(aToken);

    vm.mockCall(
      MOCK_LENDING_POOL, // 被调用的合约地址 (LendingPool)
      abi.encodeWithSelector(ILendingPool.getAssetData.selector, MOCK_UNDERLYING), // 调用的函数和参数 (getAssetData(address _asset))
      abi.encode( // 模拟的返回值，必须严格按照 getAssetData 的返回类型和顺序
        mock_isSupported,
        mock_decimals,
        mock_ltv,
        mock_liquidationThreshold,
        mock_irStrategy,
        mock_reserveFactor,
        mock_liquidationBonus,
        newLiquidityIndex, // <--- 这是我们想要模拟的存款指数
        mock_variableBorrowIndex,
        mock_lastUpdateTimestamp,
        mock_totalScaledDeposits,
        mock_totalScaledVariableBorrows,
        mock_totalReserves,
        mock_aTokenAddress
      )
    );

    // 期望的余额 = 用户的缩放余额 * 新的存款指数 / RAY
    // USER1 的 scaledBalance 是 1000e18
    uint256 expectedBalance = (depositAmount * newLiquidityIndex) / RAY;
    assertEq(aToken.balanceOf(USER1), expectedBalance, 'Balance with interest mismatch');
  }

  // 测试铸造和销毁
  function test_OnlyLendingPoolCanMintAndBurn() public {
    vm.expectRevert('AToken: Caller is not the LendingPool');
    aToken.mint(USER1, 100e18, INITIAL_LIQUIDITY_INDEX);

    vm.expectRevert('AToken: Caller is not the LendingPool');
    aToken.burn(USER1, 100e18, INITIAL_LIQUIDITY_INDEX);
  }

  function test_MintAndBurn() public {
    vm.startPrank(MOCK_LENDING_POOL);

    uint256 mintAmountUnderlying = 100e18;
    uint256 expectedScaledAmountToMint = (mintAmountUnderlying * RAY) / INITIAL_LIQUIDITY_INDEX;

    uint256 scaledBalanceBefore = aToken.scaledBalanceOf(USER1);
    uint256 scaledTotalSupplyBefore = aToken.getScaledTotalSupply();

    // 调用 mint
    uint256 actualMintedScaledAmount = aToken.mint(
      USER1,
      mintAmountUnderlying,
      INITIAL_LIQUIDITY_INDEX
    );
    assertEq(actualMintedScaledAmount, expectedScaledAmountToMint, 'Minted scaled amount mismatch');

    uint256 scaledBalanceAfterMint = aToken.scaledBalanceOf(USER1);
    uint256 scaledTotalSupplyAfterMint = aToken.getScaledTotalSupply();

    assertEq(
      scaledBalanceAfterMint,
      scaledBalanceBefore + expectedScaledAmountToMint,
      'Scaled balance after mint mismatch'
    );
    assertEq(
      scaledTotalSupplyAfterMint,
      scaledTotalSupplyBefore + expectedScaledAmountToMint,
      'Scaled total supply after mint mismatch'
    );

    // 测试销毁
    // 假设我们要销毁对应 mintAmountUnderlying 的底层资产
    uint256 burnAmountUnderlying = mintAmountUnderlying;
    uint256 expectedScaledAmountToBurn = (burnAmountUnderlying * RAY) / INITIAL_LIQUIDITY_INDEX; // 同样，这里等于 burnAmountUnderlying

    uint256 actualBurnedScaledAmount = aToken.burn(
      USER1,
      burnAmountUnderlying,
      INITIAL_LIQUIDITY_INDEX
    );
    assertEq(actualBurnedScaledAmount, expectedScaledAmountToBurn, 'Burned scaled amount mismatch');

    assertEq(
      aToken.scaledBalanceOf(USER1),
      scaledBalanceBefore,
      'Scaled balance after burn should revert to original'
    ); // 因为mint和burn的scaled量相同
    assertEq(
      aToken.getScaledTotalSupply(),
      scaledTotalSupplyBefore,
      'Scaled total supply after burn should revert to original'
    );
    vm.stopPrank();
  }
}
