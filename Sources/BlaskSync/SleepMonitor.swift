import AppKit
import IOKit.pwr_mgt

/// Reports when the lights should go dark for sleep and when they can come back.
///
/// System sleep comes through IOKit rather than `NSWorkspace.willSleepNotification`, because IOKit lets
/// the app hold off sleep until the bridge has switched the lights off; the network goes down right after.
/// Waking is reported only when the displays wake, so a dark wake (Power Nap) doesn't light up the room.
@MainActor
final class SleepMonitor {
    /// `displayOnly` is true when just the displays went to sleep and the Mac stays awake.
    private let onSleep: @MainActor (_ displayOnly: Bool) async -> Void
    private let onWake: @MainActor () async -> Void

    private var rootPort: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [NSObjectProtocol] = []

    /// Longest the Mac waits for the lights before sleeping anyway (macOS allows up to 30 s).
    private static let sleepGrace = Duration.seconds(5)

    // IOKit message numbers: iokit_common_msg(0x270) and iokit_common_msg(0x280), macros Swift can't import.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280

    init(
        onSleep: @escaping @MainActor (_ displayOnly: Bool) async -> Void, onWake: @escaping @MainActor () async -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake

        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.displaysDidSleep() }
            })
        observers.append(
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.displaysDidWake() }
            })

        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &notificationPort,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<SleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Delivered on the main queue (see IONotificationPortSetDispatchQueue below).
                MainActor.assumeIsolated { monitor.powerMessage(messageType, argument: messageArgument) }
            }, &notifier)
        if rootPort != 0, let notificationPort {
            IONotificationPortSetDispatchQueue(notificationPort, .main)
        }
    }

    isolated deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if rootPort != 0 {
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
        }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }

    private func powerMessage(_ messageType: natural_t, argument: UnsafeMutableRawPointer?) {
        let token = Int(bitPattern: argument)
        switch messageType {
        case Self.canSystemSleep:
            // Idle sleep asks first; never veto it.
            IOAllowPowerChange(rootPort, token)
        case Self.systemWillSleep:
            Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.onSleep(false) }
                    // An unreachable bridge mustn't keep the Mac awake.
                    group.addTask { try? await Task.sleep(for: Self.sleepGrace) }
                    await group.next()
                    group.cancelAll()
                }
                IOAllowPowerChange(rootPort, token)
            }
        default:
            break
        }
    }

    private func displaysDidSleep() {
        Task { await onSleep(true) }
    }

    private func displaysDidWake() {
        Task { await onWake() }
    }
}
