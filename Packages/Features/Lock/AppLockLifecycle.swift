import AppSecurity
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Collega il blocco agli eventi di sistema (§ 5.4).
    func appLockLifecycle(_ appLock: AppLock) -> some View {
        modifier(AppLockLifecycle(appLock: appLock))
    }
}

private struct AppLockLifecycle: ViewModifier {
    let appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @AppStorage(AutoLockTimeout.storageKey) private var timeout = AutoLockTimeout.default
    @State private var triggers = MacLockTriggers()
    #endif

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, newPhase in
                #if os(iOS)
                switch newPhase {
                case .active:
                    appLock.isPrivacyCovered = false
                case .inactive:
                    appLock.isPrivacyCovered = true
                case .background:
                    appLock.isPrivacyCovered = true
                    appLock.lock()
                @unknown default:
                    break
                }
                #endif
                if newPhase == .active {
                    appLock.reloadIfNeeded()
                }
            }
            #if os(macOS)
            .task(id: timeout) {
                await triggers.run(timeout: timeout.duration) { appLock.lock() }
            }
            #endif
    }
}

#if os(macOS)
/// Su Mac: blocco dopo un periodo di inattività nell'app, con lo stop o col blocco dello schermo.
@MainActor
private final class MacLockTriggers {
    private var lastActivity = ContinuousClock.now

    func run(timeout: Duration, lock: @escaping @MainActor () -> Void) async {
        lastActivity = .now
        let eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.lastActivity = .now }
            return event
        }

        var observers: [(NotificationCenter, any NSObjectProtocol)] = []
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { lock() }
            }
            observers.append((workspaceCenter, token))
        }
        let distributedCenter = DistributedNotificationCenter.default()
        let screenLocked = distributedCenter.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { lock() }
        }
        observers.append((distributedCenter, screenLocked))

        defer {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            for (center, token) in observers { center.removeObserver(token) }
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if ContinuousClock.now - lastActivity >= timeout {
                lock()
                lastActivity = .now
            }
        }
    }
}
#endif
