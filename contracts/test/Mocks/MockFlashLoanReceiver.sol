// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import 'src/Interfaces/IFlashLoanReceiver.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

contract MockFlashLoanReceiver is IFlashLoanReceiver {
  using SafeERC20 for IERC20;

  address public lendingPool;

  enum Action {
    NONE,
    DO_NOTHING_RETURN_TRUE,
    DO_NOTHING_RETURN_FALSE,
    REPAY_WITH_APPROVAL,
    DO_SOMETHING_THEN_REPAY
  }
  Action public nextAction = Action.REPAY_WITH_APPROVAL; // Default action

  event Executed(address initiator, address asset, uint256 amount, uint256 fee, bytes params);

  constructor(address _lendingPool) {
    lendingPool = _lendingPool;
  }

  function setNextAction(Action _action) external {
    nextAction = _action;
    // In a test , only owner/admin should set this
  }

  function executeOperation(
    address initiator,
    address asset,
    uint256 amount,
    uint256 fee,
    bytes calldata params
  ) external override returns (bool) {
    emit Executed(initiator, asset, amount, fee, params);

    if (msg.sender != lendingPool) {
      // Optional: check that only the lending pool can call this
      require(msg.sender == lendingPool, 'MockFlashLoanReceiver: Caller is not the LendingPool');
    }

    if (nextAction == Action.DO_NOTHING_RETURN_FALSE) {
      return false;
    }
    if (nextAction == Action.DO_NOTHING_RETURN_TRUE) {
      // This will cause flashloan to fail as funds are not approved/repaid
      return true;
    }

    // For REPAY_WITH_APPROVAL and DO_SOMETHING_THEN_REPAY
    uint256 amountToRepay = amount + fee;

    // Simulate doing something useful with the funds if needed
    if (nextAction == Action.DO_SOMETHING_THEN_REPAY) {
      // Example: transfer funds to initiator and back to test flow (not a real use case)
      IERC20(asset).safeTransfer(initiator, amount);
      IERC20(asset).safeTransferFrom(initiator, address(this), amount); // Requires initiator to approve this contract
    }

    // Approve the LendingPool to pull back the funds + fee
    IERC20(asset).approve(lendingPool, amountToRepay);

    return true;
  }
}
