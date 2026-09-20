import Foundation
import Darwin

public struct SystemMemoryStats {
    public let totalRAMBytes: UInt64
    public let freeRAMBytes: UInt64
    public let activeRAMBytes: UInt64
    public let inactiveRAMBytes: UInt64
    public let wiredRAMBytes: UInt64
    public let compressedRAMBytes: UInt64
    public let usedRAMBytes: UInt64
    public let swapUsedBytes: UInt64
    
    public var availableRAMBytes: UInt64 {
        return freeRAMBytes + inactiveRAMBytes
    }
    
    public var availableRAMMB: Double {
        return Double(availableRAMBytes) / (1024 * 1024)
    }
    
    public var usedRAMMB: Double {
        return Double(usedRAMBytes) / (1024 * 1024)
    }
}

public enum MemoryPressureLevel {
    case normal
    case warning
    case critical
}

public final class ResourceMonitor: @unchecked Sendable {
    public static let shared = ResourceMonitor()
    
    private init() {}
    
    /// Reads current system memory statistics using Mach host_statistics64.
    public func getMemoryStats() -> SystemMemoryStats {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let hostPort = mach_host_self()
        
        let kerr = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        
        var totalRAM: UInt64 = 0
        var totalRAMLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalRAM, &totalRAMLen, nil, 0)
        
        let pageSize = UInt64(vm_kernel_page_size)
        
        guard kerr == KERN_SUCCESS else {
            return SystemMemoryStats(
                totalRAMBytes: totalRAM,
                freeRAMBytes: 0,
                activeRAMBytes: 0,
                inactiveRAMBytes: 0,
                wiredRAMBytes: 0,
                compressedRAMBytes: 0,
                usedRAMBytes: 0,
                swapUsedBytes: 0
            )
        }
        
        let free = UInt64(vmStats.free_count) * pageSize
        let active = UInt64(vmStats.active_count) * pageSize
        let inactive = UInt64(vmStats.inactive_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        let used = active + wired + compressed
        
        // Query swap usage via sysctl
        var swapUsage = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapUsage, &swapLen, nil, 0)
        let swapUsed = UInt64(swapUsage.xsu_used)
        
        return SystemMemoryStats(
            totalRAMBytes: totalRAM,
            freeRAMBytes: free,
            activeRAMBytes: active,
            inactiveRAMBytes: inactive,
            wiredRAMBytes: wired,
            compressedRAMBytes: compressed,
            usedRAMBytes: used,
            swapUsedBytes: swapUsed
        )
    }
    
    /// Determines current memory pressure level.
    public func getMemoryPressureLevel() -> MemoryPressureLevel {
        let stats = getMemoryStats()
        let availableMB = stats.availableRAMMB
        
        // Based on 24GB total RAM:
        // Critical: available < 1.5 GB
        // Warning: available < 3.5 GB
        // Normal: available >= 3.5 GB
        if availableMB < 1500 {
            return .critical
        } else if availableMB < 3500 {
            return .warning
        } else {
            return .normal
        }
    }
    
    /// Suggests optimal operating mode based on live resource availability.
    public func determineRecommendedMode() -> AppOperatingMode {
        switch getMemoryPressureLevel() {
        case .normal:
            return .normal
        case .warning:
            return .lowMemory
        case .critical:
            return .emergency
        }
    }
    
    /// Returns process resident memory in Megabytes.
    public func getCurrentProcessMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0.0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
