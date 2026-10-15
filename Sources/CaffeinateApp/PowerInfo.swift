import Foundation
import IOKit
import IOKit.ps

/// Battery, lid and screen-lock readings. Public IOKit only, no root.
enum PowerInfo {
    struct Battery: Equatable {
        var percent: Int
        var onBattery: Bool
        var minutesLeft: Int?
    }

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let estimate = IOPSGetTimeRemainingEstimate()  // seconds, or negative for unknown / on AC
            return Battery(
                percent: current * 100 / max,
                onBattery: d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                minutesLeft: estimate > 0 ? Int(estimate / 60) : nil
            )
        }
        return nil
    }

    /// Battery % that `seconds` of awake time would use at the current draw.
    static func estimatedUse(seconds: Int, battery: Battery) -> Int? {
        guard battery.onBattery, let left = battery.minutesLeft, left > 0 else { return nil }
        let use = Double(battery.percent) * Double(seconds) / 60 / Double(left)
        return min(battery.percent, Int(use.rounded(.up)))
    }

    static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool ?? false
    }

    /// sysadminctl prints "screenLock delay is immediate", "... is 300 seconds" or "screenLock is off".
    static func screenLockIsImmediate() -> Bool? {
        let out = LidControl.run("/usr/sbin/sysadminctl", ["-screenLock", "status"]).output
        guard out.contains("screenLock") else { return nil }
        return out.contains("immediate")
    }

    /// Calls `handler` on the main run loop when the power source or battery level changes.
    final class Observer {
        private let handler: () -> Void
        private var source: CFRunLoopSource?

        init(_ handler: @escaping () -> Void) {
            self.handler = handler
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ ctx in
                guard let ctx else { return }
                Unmanaged<Observer>.fromOpaque(ctx).takeUnretainedValue().handler()
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }

        deinit {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        }
    }
}
