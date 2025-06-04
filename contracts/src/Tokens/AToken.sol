// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {ILendingPool} from '../Interfaces/ILendingPool.sol';
import {IAToken} from '../Interfaces/IAToken.sol';

/**
 * 核心设计：aToken 内部存储的是"缩放余额"。
 * AToken 的 _balances[user] 存储的是该用户的缩放余额。
 * AToken 的 _totalSupply 存储的是总的缩放供应量。
 * 当调用 ERC20 标准的 balanceOf() 和 totalSupply() 时，AToken 合约需要从 LendingPool 获取当前该资产的 liquidityIndex，然后将缩放余额转换为实际的底层资产数量返回。
 * mint 和 burn 操作将由 LendingPool 调用，传递的是底层资产数量，AToken 内部将其转换为缩放数量进行记账。
 */

contract AToken is ERC20, IAToken {
  // 移除 Ownable 因为 LendingPool 将是 "owner" 的 mint/burn
  ILendingPool public immutable _lendingPool;
  address public immutable _underlyingAsset;
  uint256 internal constant RAY = 1e27;

  // mapping(address => uint256) internal _scaledBalances; // ERC20._balances will store scaled balances
  // uint256 internal _scaledTotalSupply;                 // ERC20._totalSupply will store scaled total supply

  modifier onlyLendingPool() {
    require(msg.sender == address(_lendingPool), 'AToken: Caller is not the LendingPool');
    _;
  }

  /**
   * @param pool LendingPool合约地址。
   * @param underlyingAsset 底层资产地址。
   * @param tokenName aToken的名称 (例如 "Aave Interest bearing DAI")。
   * @param tokenSymbol aToken的符号 (例如 "aDAI")。
   */

  constructor(
    address pool,
    address underlyingAsset,
    string memory tokenName,
    string memory tokenSymbol
  ) ERC20(tokenName, tokenSymbol) {
    // 注意：OpenZeppelin 的 ERC20 的decimals()默认返回18。
    // 本次会在之后的LENDING_POOL.getAssetData 来更新 decimals。

    _lendingPool = ILendingPool(pool);
    _underlyingAsset = underlyingAsset;
  }

  // --- Overridden ERC20 functions ---
  /**
   * @dev 返回 aToken 的小数位数，与底层资产一致。
   */
  function decimals() public view virtual override returns (uint8) {
    ILendingPool.AssetDataReturn memory assetData = _lendingPool.getAssetData(_underlyingAsset);
    return assetData.decimals;
  }

  /**
   * @notice 返回指定账户的当前余额（已计利息的底层资产单位）。
   * @param account 要查询余额的账户地址。
   * @return 其持有的aToken代表的底层资产数量。
   */
  function balanceOf(
    address account
  ) public view virtual override(ERC20, IERC20) returns (uint256) {
    uint256 scaledBalance = super.balanceOf(account);
    if (scaledBalance == 0) {
      return 0;
    }
    ILendingPool.AssetDataReturn memory assetData = _lendingPool.getAssetData(_underlyingAsset);
    return (scaledBalance * assetData.liquidityIndex) / RAY;
  }

  /**
   * @notice 返回aToken的总供应量（已计利息的底层资产单位）。
   */
  function totalSupply() public view virtual override(ERC20, IERC20) returns (uint256) {
    uint256 scaledSupply = super.totalSupply();
    if (scaledSupply == 0) {
      return 0;
    }
    ILendingPool.AssetDataReturn memory assetData = _lendingPool.getAssetData(_underlyingAsset);
    return (scaledSupply * assetData.liquidityIndex) / RAY;
  }

  // --- IAToken specific functions ---
  function UNDERLYING_ASSET_ADDRESS() external view override returns (address) {
    return _underlyingAsset;
  }

  function LENDING_POOL() external view override returns (address) {
    return address(_lendingPool);
  }

  function scaledBalanceOf(address user) external view override returns (uint256) {
    return super.balanceOf(user); // ERC20._balances stores scaled balances
  }

  function getScaledTotalSupply() external view override returns (uint256) {
    return super.totalSupply(); // ERC20._totalSupply stores scaled total supply
  }

  // --- Restricted mint/burn functions for LendingPool ---
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
  ) external onlyLendingPool returns (uint256 mintedScaledAmount) {
    require(_liquidityIndexAtTimeOfMint > 0, 'AToken: Index connot be 0');
    mintedScaledAmount = (_amountInUnderlying * RAY) / _liquidityIndexAtTimeOfMint;
    require(mintedScaledAmount > 0, 'AToken: Amount to mint cannot be zero');
    _mint(_user, mintedScaledAmount); //Calls ERC20._mint, which updates _balances and _totalSupply (scaled)
    // emit Mint(msg.sender, _user, mintedScaledAmount, _liquidityIndexAtTimeOfMint); // msg.sender is LendingPool
    return mintedScaledAmount;
  }

  /**
   * @notice 销毁用户的 aToken (只能由 LendingPool 调用)。
   * @param _user 持有 aToken 并发起取款的用户地址。
   * @param _amountToWithdrawInUnderlying 用户希望取出的底层资产数量。
   * @param _liquidityIndexAtTimeOfBurn 取款操作时（调用_updateState后）的流动性指数。
   * @return burnedScaledAmount 实际销毁的缩放单位的aToken数量。
   */
  function burn(
    address _user,
    uint256 _amountToWithdrawInUnderlying,
    uint256 _liquidityIndexAtTimeOfBurn
  ) external onlyLendingPool returns (uint256 burnedScaledAmount) {
    require(_liquidityIndexAtTimeOfBurn > 0, 'AToken: Index cannot be zero');
    burnedScaledAmount = (_amountToWithdrawInUnderlying * RAY) / _liquidityIndexAtTimeOfBurn;
    require(burnedScaledAmount > 0, 'AToken: Amount to burn cannot be zero');

    // ERC20._burn will check if user has enough scaled balance
    _burn(_user, burnedScaledAmount); // Calls ERC20._burn
    // emit Burn(msg.sender, _user, burnedScaledAmount, _liquidityIndexAtTimeOfBurn); // msg.sender is LendingPool
    return burnedScaledAmount;
  }
}
