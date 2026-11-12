import SwiftUI
import AppKit
import IOKit.ps
import Darwin

public struct SystemMetrics: Sendable {
    public var cpuUsagePercent: Double = 0.0
    public var memoryUsedGB: Double = 0.0
    public var memoryTotalGB: Double = 0.0
    public var memoryPercent: Double = 0.0
    public var downloadBytesPerSec: Double = 0.0
    public var uploadBytesPerSec: Double = 0.0
    public var batteryLevel: Int = 100
    public var isCharging: Bool = false
    public var isACPowered: Bool = true
}

@MainActor
public final class SystemMonitorManager: ObservableObject {
    public static let shared = SystemMonitorManager()

    @Published public private(set) var metrics = SystemMetrics()
    @Published public var showChargingBanner: Bool = false
    @Published public var chargingBannerDismissTimer: Timer?

    private var monitorTimer: Timer?
    private var previousCpuLoad: host_cpu_load_info?
    private var previousNetworkBytes: (inBytes: UInt64, outBytes: UInt64, time: Date)?
    private var lastChargingState: Bool?

    private init() {
        startMonitoring()
        setupSleepObservers()
    }

    // Suspend monitoring when display is asleep to save battery
    private func setupSleepObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopMonitoring()
            }
        }
        wsCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.startMonitoring()
            }
        }
    }

    public func startMonitoring() {
        guard monitorTimer == nil else { return }
        refreshMetrics()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetrics()
            }
        }
    }

    public func stopMonitoring() {
        monitorTimer?.invalidate()
        monitorTimer = nil
    }

    public func refreshMetrics() {
        let cpu = readCpuUsage()
        let (memUsed, memTotal, memPct) = readMemoryUsage()
        let (downSpeed, upSpeed) = readNetworkSpeeds()
        let (battery, isCharging, isAC) = readPowerStatus()

        // Check for charger connection event (MagSafe animation trigger)
        if let lastState = lastChargingState {
            if !lastState && isCharging {
                triggerChargingBanner()
            }
        }
        lastChargingState = isCharging

        metrics = SystemMetrics(
            cpuUsagePercent: cpu,
            memoryUsedGB: memUsed,
            memoryTotalGB: memTotal,
            memoryPercent: memPct,
            downloadBytesPerSec: downSpeed,
            uploadBytesPerSec: upSpeed,
            batteryLevel: battery,
            isCharging: isCharging,
            isACPowered: isAC
        )
    }

    public func triggerChargingBanner() {
        showChargingBanner = true
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        chargingBannerDismissTimer?.invalidate()
        chargingBannerDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self?.showChargingBanner = false
                }
            }
        }
    }

    // MARK: - CPU Load via host_statistics

    private func readCpuUsage() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var cpuLoad = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0.0 }

        defer { previousCpuLoad = cpuLoad }
        guard let prev = previousCpuLoad else { return 0.0 }

        let user = Double(cpuLoad.cpu_ticks.0 - prev.cpu_ticks.0)
        let system = Double(cpuLoad.cpu_ticks.1 - prev.cpu_ticks.1)
        let idle = Double(cpuLoad.cpu_ticks.2 - prev.cpu_ticks.2)
        let nice = Double(cpuLoad.cpu_ticks.3 - prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0.0 }
        return ((user + system + nice) / total) * 100.0
    }

    // MARK: - Memory Usage via host_statistics64

    private func readMemoryUsage() -> (usedGB: Double, totalGB: Double, percent: Double) {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStat = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &vmStat) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(totalBytes) / (1024 * 1024 * 1024)

        guard result == KERN_SUCCESS else { return (0, totalGB, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let active = Double(vmStat.active_count) * pageSize
        let wired = Double(vmStat.wire_count) * pageSize
        let compressed = Double(vmStat.compressor_page_count) * pageSize
        let usedBytes = active + wired + compressed
        let usedGB = usedBytes / (1024 * 1024 * 1024)
        let percent = min(100.0, max(0.0, (usedGB / totalGB) * 100.0))

        return (usedGB, totalGB, percent)
    }

    // MARK: - Network Transfer Speeds via getifaddrs

    private func readNetworkSpeeds() -> (downSpeed: Double, upSpeed: Double) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let name = String(cString: current.pointee.ifa_name)
            if !name.hasPrefix("lo") && current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK) {
                if let data = current.pointee.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self)
                    totalIn += UInt64(networkData.pointee.ifi_ibytes)
                    totalOut += UInt64(networkData.pointee.ifi_obytes)
                }
            }
            ptr = current.pointee.ifa_next
        }

        let now = Date()
        defer { previousNetworkBytes = (totalIn, totalOut, now) }
        guard let prev = previousNetworkBytes else { return (0, 0) }

        let elapsed = max(0.5, now.timeIntervalSince(prev.time))
        let downSpeed = Double(totalIn >= prev.inBytes ? totalIn - prev.inBytes : 0) / elapsed
        let upSpeed = Double(totalOut >= prev.outBytes ? totalOut - prev.outBytes : 0) / elapsed

        return (downSpeed, upSpeed)
    }

    // MARK: - Power & Battery Status via IOKit

    private func readPowerStatus() -> (batteryLevel: Int, isCharging: Bool, isAC: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              !sources.isEmpty else {
            return (100, false, true)
        }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let curCapacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
            let powerSourceState = desc[kIOPSPowerSourceStateKey as String] as? String
            let isAC = (powerSourceState == (kIOPSACPowerValue as String))
            return (curCapacity, isCharging, isAC)
        }

        return (100, false, true)
    }

    // Formatters
    public static func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1024 * 1024 {
            return String(format: "%.1fM", bytesPerSec / (1024 * 1024))
        } else if bytesPerSec >= 1024 {
            return String(format: "%.0fK", bytesPerSec / 1024)
        } else {
            return "\(Int(bytesPerSec))B"
        }
    }
}
