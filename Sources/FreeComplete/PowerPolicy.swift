import Foundation
import IOKit.ps

enum PowerMode: String, CaseIterable, Identifiable {
    case automatic, performance, batterySaver

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .performance: "Performance"
        case .batterySaver: "Battery Saver"
        }
    }
}

struct PowerEnvironment: Equatable {
    /// Nil means macOS did not report a usable power source, not that AC is connected.
    var onBattery: Bool?
    var lowPowerMode: Bool
}

struct PowerPolicy: Equatable {
    let savesEnergy: Bool
    let description: String

    var preloadsModel: Bool { !savesEnergy }
    var prefetchesContinuation: Bool { !savesEnergy }
    var debounce: Duration { .milliseconds(savesEnergy ? 120 : 30) }
    var idleUnloadDelay: Duration? { savesEnergy ? .seconds(60) : nil }

    static func resolve(mode: PowerMode, environment: PowerEnvironment) -> PowerPolicy {
        switch mode {
        case .performance:
            return PowerPolicy(savesEnergy: false,
                description: "Performance: keeps the model ready and prepares the next continuation.")
        case .batterySaver:
            return PowerPolicy(savesEnergy: true,
                description: "Battery Saver: no advance loading or continuation prefetch; unloads after 60 seconds idle.")
        case .automatic:
            let reason: String
            let savesEnergy: Bool
            if environment.lowPowerMode {
                reason = "Low Power Mode is on"
                savesEnergy = true
            } else if let onBattery = environment.onBattery {
                reason = onBattery ? "running on battery" : "connected to power"
                savesEnergy = onBattery
            } else {
                reason = "power source unavailable"
                savesEnergy = true
            }
            return PowerPolicy(savesEnergy: savesEnergy,
                description: "Automatic: \(savesEnergy ? "Battery Saver" : "Performance") (\(reason)).")
        }
    }
}

/// IOKit reports AC/battery changes even when Low Power Mode stays unchanged.
/// The run-loop source and Foundation observer are kept alive together.
@MainActor
final class SystemPowerMonitor {
    private var source: CFRunLoopSource?
    private var lowPowerObserver: NSObjectProtocol?
    var onChange: ((PowerEnvironment) -> Void)?

    static func current() -> PowerEnvironment {
        var onBattery: Bool?
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            let name = source as String
            if name == kIOPSBatteryPowerValue { onBattery = true }
            else if name == kIOPSACPowerValue { onBattery = false }
        }
        return PowerEnvironment(onBattery: onBattery, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func start() {
        guard source == nil, lowPowerObserver == nil else { return }
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // The source is installed only on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<SystemPowerMonitor>.fromOpaque(context).takeUnretainedValue().changed()
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        if let lowPowerObserver { NotificationCenter.default.removeObserver(lowPowerObserver) }
        lowPowerObserver = nil
    }

    private func changed() { onChange?(Self.current()) }
}
