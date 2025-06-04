import { formatUnits } from 'viem';

export const DEFAULT_TOKEN_DISPLAY_DECIMALS = 4; // 代币金额默认显示的小数位数
export const USD_DISPLAY_DECIMALS = 2;         // USD 金额默认显示的小数位数
export const PERCENTAGE_DISPLAY_DECIMALS = 2;  // 百分比显示的小数位数

/**
 * 格式化大数字（通常是 bigint）为用户可读的字符串，并指定小数位数。
 * @param value 要格式化的值 (bigint | undefined)
 * @param baseDecimals 原始值的基准小数位数 (例如代币的 decimals)
 * @param displayDecimals 希望显示的小数位数
 * @returns 格式化后的字符串，或 "N/A"
 */
export function formatDisplayNumber(
  value: bigint | undefined,
  baseDecimals: number,
  displayDecimals: number
): string {
  if (value === undefined || value === null) return 'N/A';
  try {
    const formatted = formatUnits(value, baseDecimals);
    const num = parseFloat(formatted);
    if (isNaN(num)) return 'N/A';

    // 对于非常小但非零的值，避免显示 "0.00"
    if (num > 0 && num < Math.pow(10, -displayDecimals)) {
      return `< ${Math.pow(10, -displayDecimals).toFixed(displayDecimals)}`;
    }
    return num.toFixed(displayDecimals);
  } catch (error) {
    console.error("Error formatting number:", error, { value, baseDecimals, displayDecimals });
    return 'Error';
  }
}

/**
 * 格式化百分比 (通常来自 RAY 或 BPS 单位的 bigint)
 * @param valueInRayOrBps RAY (1e27) 或 BPS (1e4) 单位的 bigint 值
 * @param sourceUnitIsRay true 如果输入是 RAY 单位, false 如果是 BPS (或其他，需要调整分母)
 * @returns 格式化后的百分比字符串 (例如 "12.34%")
 */
export function formatPercentage(
    valueInRayOrBps: bigint | undefined,
    sourceUnitIsRay: boolean = true // 默认为 RAY 单位
): string {
    if (valueInRayOrBps === undefined || valueInRayOrBps === null) return 'N/A';
    
    const RAY_BI = 10n ** 27n;
    const BASIS_POINTS_FACTOR = 10000n; // 100.00% = 10000 BPS
    const PERCENTAGE_DENOMINATOR = 100n; // 用于从基点转换为百分比

    try {
        let valueInBasisPoints: bigint;
        if (sourceUnitIsRay) {
            valueInBasisPoints = (valueInRayOrBps * BASIS_POINTS_FACTOR) / RAY_BI;
        } else { // 假设是 BPS (10000 = 100%)
            valueInBasisPoints = valueInRayOrBps; 
        }
        
        const percentage = Number(valueInBasisPoints) / Number(PERCENTAGE_DENOMINATOR);
        if (isNaN(percentage)) return 'N/A';

        return `${percentage.toFixed(PERCENTAGE_DISPLAY_DECIMALS)}%`;

    } catch (error) {
        console.error("Error formatting percentage:", error, { valueInRayOrBps, sourceUnitIsRay });
        return 'Error';
    }
}