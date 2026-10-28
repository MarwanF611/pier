import CSensors
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Observation

/// One reading of everything the dock shows about the machine.
struct SystemSnapshot: Equatable {
    var cpuUsage: Double = 0            // 0...1, all cores
    var gpuUsage: Double?               // 0...1
    var cpuTemperature: Double?         // °C
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var swapUsed: UInt64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var downloadRate: Double = 0        // bytes per second
    var uploadRate: Double = 0
    var batteryLevel: Double?           // 0...1
    var isCharging = false
    /// On the charger, whether or not the battery is still filling.
    var isPluggedIn = false
    var uptime: TimeInterval = 0
    var thermalState: ProcessInfo.ThermalState = .nominal

    var memoryUsage: Double { memoryTotal == 0 ? 0 : Double(memoryUsed) / Double(memoryTotal) }
    var memoryAvailable: UInt64 { memoryTotal > memoryUsed ? memoryTotal - memoryUsed : 0 }
    var diskUsage: Double { diskTotal == 0 ? 0 : 1 - Double(diskFree) / Double(diskTotal) }
}

@MainActor
@Observable
final class SystemMonitor {
    private(set) var snapshot = SystemSnapshot()
    /// Recent CPU usage samples, oldest first, for the sparkline.
    private(set) var cpuHistory: [Double] = Array(repeating: 0, count: 60)

    /// Called on the main actor with every new snapshot.
    @ObservationIgnored var onSample: ((SystemSnapshot) -> Void)?

    private let sampler = Sampler()
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?

    func start(interval: TimeInterval = 2) {
        refresh()
        // Plugging in the charger shows up right away instead of at the next tick.
        if powerSource == nil, let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = interval * 0.2
    }

    /// Re-reads disk space right away, for example after a cleanup.
    func refresh() {
        let sampler = sampler
        Task.detached(priority: .utility) {
            let snapshot = sampler.sample()
            await MainActor.run {
                self.snapshot = snapshot
                self.cpuHistory.removeFirst()
                self.cpuHistory.append(snapshot.cpuUsage)
                self.onSample?(snapshot)
            }
        }
    }
}

/// Reads kernel counters. Keeps the previous counters so rates can be computed;
/// only ever called from one detached task at a time.
private final class Sampler: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPUTicks: [(busy: UInt64, total: UInt64)] = []
    private var previousNetwork: (received: UInt64, sent: UInt64, at: Date)?

    func sample() -> SystemSnapshot {
        lock.lock(); defer { lock.unlock() }

        var s = SystemSnapshot()
        s.cpuUsage = cpuUsage()
        s.gpuUsage = gpuUsage()
        let temperature = pier_cpu_temperature()
        s.cpuTemperature = temperature > 0 ? temperature : nil
        s.memoryUsed = memoryUsed()
        s.swapUsed = swapUsed()
        (s.diskFree, s.diskTotal) = diskSpace()
        (s.downloadRate, s.uploadRate) = networkRates()
        (s.batteryLevel, s.isCharging, s.isPluggedIn) = battery()
        s.uptime = ProcessInfo.processInfo.systemUptime
        s.thermalState = ProcessInfo.processInfo.thermalState
        return s
    }

    private func cpuUsage() -> Double {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var ticks: [(busy: UInt64, total: UInt64)] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + system + nice, user + system + nice + idle))
        }
        defer { previousCPUTicks = ticks }
        guard previousCPUTicks.count == ticks.count else { return 0 }

        var busy: UInt64 = 0, total: UInt64 = 0
        for (now, before) in zip(ticks, previousCPUTicks) where now.total >= before.total {
            busy += now.busy &- before.busy
            total += now.total &- before.total
        }
        return total == 0 ? 0 : min(1, Double(busy) / Double(total))
    }

    private func gpuUsage() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var result: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let utilization = stats["Device Utilization %"] as? NSNumber else { continue }
            result = max(result ?? 0, utilization.doubleValue / 100)
        }
        return result
    }

    /// Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
    private func memoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(vm_kernel_page_size)
        let appPages = UInt64(stats.internal_page_count) - UInt64(min(stats.purgeable_count, stats.internal_page_count))
        return (appPages + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
    }

    private func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    private func diskSpace() -> (free: Int64, total: Int64) {
        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        return (values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeTotalCapacity ?? 0))
    }

    private func networkRates() -> (down: Double, up: Double) {
        var received: UInt64 = 0, sent: UInt64 = 0
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  (interface.ifa_flags & UInt32(IFF_UP)) != 0,
                  (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            // Physical interfaces only (Wi-Fi, Ethernet); VPN tunnels would double count.
            guard String(cString: interface.ifa_name).hasPrefix("en") else { continue }
            received += UInt64(data.pointee.ifi_ibytes)
            sent += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        defer { previousNetwork = (received, sent, now) }
        guard let previous = previousNetwork else { return (0, 0) }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0 else { return (0, 0) }
        // The counters are 32-bit per interface and wrap; treat a drop as a wrap or reset.
        let down = received >= previous.received ? Double(received - previous.received) : 0
        let up = sent >= previous.sent ? Double(sent - previous.sent) : 0
        return (down / elapsed, up / elapsed)
    }

    private func battery() -> (level: Double?, charging: Bool, pluggedIn: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, false, false) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let pluggedIn = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (Double(current) / Double(maximum), charging, pluggedIn)
        }
        return (nil, false, false)
    }
}
