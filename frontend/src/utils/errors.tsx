import { BaseError } from 'viem'; // 从 viem 导入 BaseError

export function getErrorMessage(error: any): string {
  if (error instanceof BaseError) {
    // viem/wagmi 的错误通常是 BaseError 的实例
    if (error.shortMessage) return error.shortMessage;
    if (error.message) return error.message; // BaseError 也有 message
  }
  if (error instanceof Error) {
    // 标准 JavaScript Error
    if (error.message) return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  return '发生未知错误 (An unknown error occurred)';
}
