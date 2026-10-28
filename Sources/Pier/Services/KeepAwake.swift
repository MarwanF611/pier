import Foundation
import IOKit.pwr_mgt
import Observation

/// Stops the Mac from going to sleep on its own while a long job runs, the way `caffeinate`
/// does. The screen can still turn off; work carries on behind it. Closing a MacBook's lid
/// still puts it to sleep, and quitting Pier ends it.
@MainActor
@Observable
final class KeepAwake {
    private(set) var isOn = false
    /// When it turns itself off, or nil to stay on until turned off.
    private(set) var until: Date?

    @ObservationIgnored private var assertion = IOPMAssertionID(0)
    @ObservationIgnored private var expiry: Task<Void, Never>?

    static let durations: [(title: String, seconds: TimeInterval?)] = [
        ("Until Turned Off", nil), ("For 1 Hour", 3600), ("For 2 Hours", 7200), ("For 4 Hours", 14_400),
    ]

    func turnOn(for duration: TimeInterval? = nil) {
        if !isOn {
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                              IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                              "Pier: Keep Awake" as CFString, &assertion) == kIOReturnSuccess else { return }
            isOn = true
        }
        expiry?.cancel()
        until = duration.map { .now.addingTimeInterval($0) }
        guard let duration else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { self?.turnOff() }
        }
    }

    func turnOff() {
        expiry?.cancel()
        expiry = nil
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        isOn = false
        until = nil
    }

    /// "Keeping your Mac awake until 15:30", for tooltips and VoiceOver.
    var summary: String {
        guard isOn else { return "Keep Awake is off" }
        guard let until else { return "Keeping your Mac awake until you turn it off" }
        return "Keeping your Mac awake until \(until.formatted(date: .omitted, time: .shortened))"
    }
}
