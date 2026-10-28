import AppKit
import CoreAudio
import Observation
import SwiftUI

/// Something worth a few seconds beside the notch, the way the Dynamic Island shows a
/// charger being plugged in: a symbol on one side, a short text on the other.
struct LiveActivity: Equatable {
    var symbol: String
    var text: String
    var tint: Color
    /// What VoiceOver announces, since the text alone ("64%") says little.
    var spoken: String
    var id = UUID()
}

/// Turns changes on the Mac into live activities: the charger plugged in, headphones
/// connecting, and readings that stay critical.
@MainActor
@Observable
final class LiveActivities {
    private(set) var current: LiveActivity?

    @ObservationIgnored private var previous: SystemSnapshot?
    @ObservationIgnored private var criticalSince: [NotchStat: Date] = [:]
    @ObservationIgnored private var lastWarned: [NotchStat: Date] = [:]
    @ObservationIgnored private let audio = AudioOutputWatcher()

    /// A reading has to stay critical this long before it is worth interrupting for (a fanless
    /// Mac touches 90 °C on every short burst of work), and is then not raised again for a while.
    private static let warnAfter: TimeInterval = 30
    private static let warnAgainAfter: TimeInterval = 30 * 60

    func start() {
        audio.onBluetoothOutput = { [weak self] name in
            self?.show(LiveActivity(symbol: Self.headphoneSymbol(for: name), text: name, tint: .white,
                                    spoken: "\(name) connected"))
        }
        audio.start()
    }

    func show(_ activity: LiveActivity, for seconds: TimeInterval = 4) {
        current = activity
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: activity.spoken,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.current?.id == activity.id { self?.current = nil }
        }
    }

    /// Called with every new reading from the system monitor.
    func observe(_ snapshot: SystemSnapshot) {
        defer { previous = snapshot }
        // The first reading only sets the baseline: being plugged in at launch is not news.
        guard let previous else { return }

        if snapshot.isPluggedIn, !previous.isPluggedIn, let level = snapshot.batteryLevel {
            show(LiveActivity(symbol: "bolt.fill", text: level.percent, tint: .green, spoken: "Charging, \(level.percent)"))
        }

        let now = Date.now
        for stat in [NotchStat.temperature, .memory, .disk] {
            let reading = NotchEars.reading(stat, snapshot)
            guard reading.severity == .critical else { criticalSince[stat] = nil; continue }
            let since = criticalSince[stat] ?? now
            criticalSince[stat] = since
            guard now.timeIntervalSince(since) >= Self.warnAfter,
                  lastWarned[stat].map({ now.timeIntervalSince($0) >= Self.warnAgainAfter }) ?? true else { continue }
            lastWarned[stat] = now
            show(LiveActivity(symbol: reading.symbol, text: reading.value, tint: .red,
                              spoken: "\(stat.title) is high: \(reading.value)"), for: 6)
        }
    }

    private static func headphoneSymbol(for name: String) -> String {
        let name = name.lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") { return "beats.headphones" }
        return "headphones"
    }
}

/// Reports when the default audio output switches to a Bluetooth device, which is how AirPods
/// and other headphones arrive. Core Audio needs no Bluetooth permission for this.
@MainActor
private final class AudioOutputWatcher {
    var onBluetoothOutput: ((String) -> Void)?

    func start() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
    }

    private func defaultOutputChanged() {
        guard let device = Self.property(kAudioHardwarePropertyDefaultOutputDevice, of: AudioObjectID(kAudioObjectSystemObject),
                                         as: AudioDeviceID.self),
              let transport = Self.property(kAudioDevicePropertyTransportType, of: device, as: UInt32.self),
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
              let name = Self.property(kAudioObjectPropertyName, of: device, as: Unmanaged<CFString>.self)?.takeRetainedValue()
        else { return }
        onBluetoothOutput?(name as String)
    }

    private static func property<Value>(_ selector: AudioObjectPropertySelector, of object: AudioObjectID, as _: Value.Type) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutablePointer<Value>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }
}
