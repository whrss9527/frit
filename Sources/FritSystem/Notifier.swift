import UserNotifications

/// System notification delivery with parameterised categories.
///
/// Proxi-shaped: the notifier owns `UNUserNotificationCenter` delegation,
/// requests authorization lazily on first use, and delivers the route string
/// back through `onOpen`. Each app registers its own notification categories
/// (e.g. an "Install Update" action) via `registerCategories(_:)`.
public final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let available: Bool
    private var authorized = false

    /// Called when the user taps the notification body. The parameter is the
    /// `route` string that was passed to `show(title:body:route:category:)`.
    public var onOpen: (@Sendable (String?) -> Void)?
    /// Called when the user taps a custom action button on the notification.
    /// The parameter is the action identifier (e.g. "install-update").
    public var onAction: (@Sendable (String, String?) -> Void)?

    /// Creates a notifier. Set `bundleIdentifier` to `nil` when the process
    /// is not bundled (e.g. running from the command line); notifications are
    /// silently no-ops in that case.
    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        available = bundleIdentifier != nil
        super.init()
        if available {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// Registers notification categories before the first notification is
    /// shown. Call once at startup so that tapping an old notification
    /// delivered before a relaunch still works.
    public func registerCategories(_ categories: [UNNotificationCategory]) {
        guard available else { return }
        UNUserNotificationCenter.current().setNotificationCategories(Set(categories))
    }

    // MARK: - Authorization

    /// Requests alert + sound authorization. Safe to call multiple times;
    /// the system prompt only appears the first time.
    public func requestAuthorization() {
        guard available, !authorized else { return }
        authorized = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Delivering

    /// Shows a notification immediately. Authorization is requested
    /// automatically on the first call.
    ///
    /// - Parameters:
    ///   - category: The category identifier, which must match a category
    ///     previously registered via `registerCategories(_:)`.
    ///   - route: An opaque string the app can inspect when the user opens
    ///     the notification, for example a settings page key.
    public func show(title: String,
                     body: String,
                     route: String? = nil,
                     category: String? = nil) {
        guard available else { return }
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let route {
            content.userInfo = ["route": route]
        }
        if let category {
            content.categoryIdentifier = category
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let route = response.notification.request.content.userInfo["route"] as? String
        if action == UNNotificationDefaultActionIdentifier {
            onOpen?(route)
        } else if action != UNNotificationDismissActionIdentifier {
            onAction?(action, route)
        }
        completionHandler()
    }
}