import Foundation
import MachO
import Darwin

/// Helper class to monitor macOS system statistics with zero lag and minimal CPU overhead.
class SystemStatsHelper {
    static let shared = SystemStatsHelper()
    
    private let cpuMonitor = CPUUsageMonitor()
    private let netMonitor = NetworkSpeedMonitor()
    
    private init() {}
    
    func getCPUUsage() -> Double {
        return cpuMonitor.getUsage()
    }
    
    func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }
        
        let pageSize = vm_kernel_page_size
        let active = Double(stats.active_count) * Double(pageSize)
        let wire = Double(stats.wire_count) * Double(pageSize)
        let compressed = Double(stats.compressor_page_count) * Double(pageSize)
        let inactive = Double(stats.inactive_count) * Double(pageSize)
        
        let used = active + wire + compressed
        let total = used + inactive + Double(stats.free_count) * Double(pageSize)
        
        guard total > 0 else { return 0.0 }
        return (used / total) * 100.0
    }
    
    func getNetworkSpeeds() -> (uploadSpeed: Double, downloadSpeed: Double) {
        return netMonitor.getSpeeds()
    }
}

// MARK: - CPU Usage Monitor
private class CPUUsageMonitor {
    private var prevCpuInfo: processor_info_array_t?
    private var numCpuInfo: mach_msg_type_number_t = 0
    private var numCPUs: uint32 = 0
    private let lock = NSLock()

    init() {
        var size = MemoryLayout<uint32>.size
        var mib = [CTL_HW, HW_NCPU]
        sysctl(&mib, 2, &numCPUs, &size, nil, 0)
    }

    func getUsage() -> Double {
        var numCPUsU: mach_msg_type_number_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfoU: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfoU)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return 0.0
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        var totalUsage: Double = 0.0
        if let prevInfo = prevCpuInfo {
            for i in 0..<Int(numCPUs) {
                let base = i * Int(CPU_STATE_MAX)
                let user = cpuInfo[base + Int(CPU_STATE_USER)] - prevInfo[base + Int(CPU_STATE_USER)]
                let system = cpuInfo[base + Int(CPU_STATE_SYSTEM)] - prevInfo[base + Int(CPU_STATE_SYSTEM)]
                let idle = cpuInfo[base + Int(CPU_STATE_IDLE)] - prevInfo[base + Int(CPU_STATE_IDLE)]
                let nice = cpuInfo[base + Int(CPU_STATE_NICE)] - prevInfo[base + Int(CPU_STATE_NICE)]
                
                let inUse = user + system + nice
                let total = inUse + idle
                
                if total > 0 {
                    totalUsage += Double(inUse) / Double(total)
                }
            }
            
            // Deallocate previous info
            let prevSize = MemoryLayout<integer_t>.size * Int(numCpuInfo)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: Int(bitPattern: prevInfo)), vm_size_t(prevSize))
        }
        
        prevCpuInfo = cpuInfo
        numCpuInfo = numCpuInfoU
        
        let finalUsage = (totalUsage / Double(numCPUs)) * 100.0
        return min(100.0, max(0.0, finalUsage))
    }
    
    deinit {
        if let prevInfo = prevCpuInfo {
            let prevSize = MemoryLayout<integer_t>.size * Int(numCpuInfo)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: Int(bitPattern: prevInfo)), vm_size_t(prevSize))
        }
    }
}

// MARK: - Network Speed Monitor
private class NetworkSpeedMonitor {
    private var prevBytesIn: UInt64 = 0
    private var prevBytesOut: UInt64 = 0
    private var lastTime: Date = Date()
    
    func getSpeeds() -> (uploadSpeed: Double, downloadSpeed: Double) {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return (0, 0) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            if (flags & IFF_UP) == IFF_UP {
                let name = String(cString: ptr.pointee.ifa_name)
                // Filter main interface prefixes en (wi-fi/ethernet) and ap (access points)
                if name.hasPrefix("en") || name.hasPrefix("ap") {
                    if ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                        if let ifData = ptr.pointee.ifa_data {
                            let bound = ifData.assumingMemoryBound(to: if_data.self)
                            bytesIn += UInt64(bound.pointee.ifi_ibytes)
                            bytesOut += UInt64(bound.pointee.ifi_obytes)
                        }
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastTime)
        lastTime = now
        
        guard elapsed > 0.05 else { return (0, 0) }
        
        // Return 0 if it's the first sample
        if prevBytesIn == 0 && prevBytesOut == 0 {
            prevBytesIn = bytesIn
            prevBytesOut = bytesOut
            return (0, 0)
        }
        
        let upSpeed = Double(bytesOut > prevBytesOut ? bytesOut - prevBytesOut : 0) / elapsed
        let downSpeed = Double(bytesIn > prevBytesIn ? bytesIn - prevBytesIn : 0) / elapsed
        
        prevBytesIn = bytesIn
        prevBytesOut = bytesOut
        
        return (upSpeed, downSpeed)
    }
}
