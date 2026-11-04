// The app's foreground and background transitions, passed in (plan
// lasa-swift.md §2.2, decision 6 of 2026-11-03): the client never
// subscribes to UIApplication itself. An app with its own scene
// handling conforms its own object; one without constructs
// UIApplicationLifecycle and passes that.

import Foundation

public enum AppTransition: Sendable {
    case willResignActive
    case didEnterBackground
    case willEnterForeground
    case didBecomeActive
}

/// A hold on the process for a short piece of work after the app has
/// entered the background (the close of §4): the lifecycle object's
/// own mechanism, `UIApplication.beginBackgroundTask` in the
/// convenience. `end()` releases it; releasing twice is harmless.
public protocol BackgroundHold: Sendable {
    func end()
}

public protocol AppLifecycle: Sendable {
    var transitions: AsyncStream<AppTransition> { get }
    /// Asks the app to keep the process running while the library does
    /// `name`; nil when the app has no such mechanism, in which case the
    /// work runs on whatever time the system allows.
    @MainActor func hold(for name: String) -> BackgroundHold?
}

public extension AppLifecycle {
    @MainActor func hold(for name: String) -> BackgroundHold? { nil }
}

#if os(iOS)
import UIKit

/// The convenience: wraps UIApplication's notifications. The app
/// constructs it and hands it to the client; the library never
/// subscribes to UIApplication on its own.
public final class UIApplicationLifecycle: AppLifecycle, @unchecked Sendable {
    public let transitions: AsyncStream<AppTransition>
    private var observers: [NSObjectProtocol] = []

    public init(center: NotificationCenter = .default) {
        let (stream, cont) = AsyncStream<AppTransition>.makeStream(bufferingPolicy: .bufferingNewest(8))
        transitions = stream
        let pairs: [(Notification.Name, AppTransition)] = [
            (UIApplication.willResignActiveNotification, .willResignActive),
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
            (UIApplication.didBecomeActiveNotification, .didBecomeActive),
        ]
        for (name, t) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in cont.yield(t) })
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// A UIKit background task: about thirty seconds, the expiration
    /// handler ending it if the work has not.
    public func hold(for name: String) -> BackgroundHold? {
        let h = UIKitHold()
        h.id = UIApplication.shared.beginBackgroundTask(withName: name) { h.end() }
        return h.id == .invalid ? nil : h
    }

    private final class UIKitHold: BackgroundHold, @unchecked Sendable {
        var id: UIBackgroundTaskIdentifier = .invalid
        private let lock = NSLock()
        func end() {
            lock.lock()
            let id = self.id
            self.id = .invalid
            lock.unlock()
            guard id != .invalid else { return }
            Task { @MainActor in UIApplication.shared.endBackgroundTask(id) }
        }
    }
}
#endif
