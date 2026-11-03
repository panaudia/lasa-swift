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

public protocol AppLifecycle: Sendable {
    var transitions: AsyncStream<AppTransition> { get }
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
}
#endif
