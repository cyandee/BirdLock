import Foundation

/// Bound parallel work by both CPU count and estimated live image memory.
public enum ResourceBudget {
    public static func workers(bytesPerTask: Int, maximum: Int = 16,
                               cpu: Int = ProcessInfo.processInfo.activeProcessorCount,
                               memory: UInt64 = ProcessInfo.processInfo.physicalMemory,
                               lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> Int {
        let budget = max(UInt64(128 << 20), min(UInt64(1536 << 20), memory / 12))
        let byMemory = max(1, Int(budget / UInt64(max(1,bytesPerTask))))
        return max(1,min(lowPower ? min(2,maximum) : maximum,max(1,cpu-2),byMemory))
    }
}
