// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IAToken is IERC20 {
  /**
   * @notice 返回底层资产的地址。
   */
  function UNDERLYING_ASSET_ADDRESS() external view returns (address);

  /**
   * @notice 返回关联的 LendingPool 地址。
   */
  function LENDING_POOL() external view returns (address);

  /**
   * @notice 返回用户的缩放余额 (scaled balance)。
   * @param user 用户地址。
   * @return 用户持有的 aToken 代表的缩放单位数量。
   */
  function scaledBalanceOf(address user) external view returns (uint256);

  /**
   * @notice 返回 aToken 的总缩放供应量。
   */
  function getScaledTotalSupply() external view returns (uint256);

  /**
   * @notice 铸造 aToken 给用户 (只能由 LendingPool 调用)。
   * @param _user 接收 aToken 的用户地址。
   * @param _amountInUnderlying 用户存入的底层资产数量。
   * @param _liquidityIndexAtTimeOfMint 存款操作时（调用_updateState后）的流动性指数。
   * @return mintedScaledAmount 实际铸造的缩放单位的aToken数量。
   */
  function mint(
    address _user,
    uint256 _amountInUnderlying,
    uint256 _liquidityIndexAtTimeOfMint
  ) external returns (uint256);

  /**
   * @notice 销毁用户的 aToken (只能由 LendingPool 调用)。
   * @param _user 被销毁 aToken 的用户地址。
   * @param _amountInUnderlying 用户取出的底层资产数量。
   * @param _liquidityIndexAtTimeOfBurn 取款操作时（调用_updateState后）的流动性指数。
   * @return burnedScaledAmount 实际销毁的缩放单位的aToken数量。
   */
  function burn(
    address _user,
    uint256 _amountInUnderlying,
    uint256 _liquidityIndexAtTimeOfBurn
  ) external returns (uint256);

  // Aave aToken 有更复杂的 mint/burn 逻辑和权限控制，这里简化
  // 通常 mint 和 burn 只能由 LendingPool 调用
  // event Mint(address indexed caller, address indexed onBehalfOf, uint256 value, uint256 index);
  // event Burn(address indexed from, address indexed target, uint256 value, uint256 index);
}
