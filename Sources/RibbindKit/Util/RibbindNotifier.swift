import Foundation
import UserNotifications

/// Tiny wrapper around `UNUserNotificationCenter` for surfacing dispatch
/// errors to the user as macOS notifications (Notification Center). First-use
/// authorization is requested lazily; if the user denies, calls become silent
/// no-ops (with NSLog fallback).
public enum RibbindNotifier {
    private static let center = UNUserNotificationCenter.current()
    private static var authChecked = false
    private static var authGranted = false

    /// Show a notification with title + body. Idempotent: requests authorization
    /// on first call only. Silent no-op if user denied notifications.
    @MainActor
    public static func notify(title: String, body: String) {
        ensureAuthorized { granted in
            guard granted else {
                NSLog("[Ribbind] notify (denied/skipped): %@ — %@", title, body)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            center.add(req) { error in
                if let error {
                    NSLog("[Ribbind] notify failed: %@", String(describing: error))
                }
            }
        }
    }

    private static func ensureAuthorized(_ then: @escaping (Bool) -> Void) {
        if authChecked { then(authGranted); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authChecked = true
            authGranted = granted
            then(granted)
        }
    }
}
