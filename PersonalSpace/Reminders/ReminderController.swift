import Combine
import Foundation
import OSLog
import UserNotifications

struct ReminderResult: Sendable {
    let scheduled: Bool
    let message: String
}

/// System notification operations run only after the caller has saved an action.
@MainActor
final class ReminderController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    var onOpenAction: (@MainActor (String) -> Void)?

    private let center: UNUserNotificationCenter
    private let logger = Logger(subsystem: "com.liamamilin.PersonalSpace", category: "Reminders")

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    nonisolated static func identifier(for actionID: String) -> String {
        "action.\(actionID)"
    }

    func apply(
        actionID: String,
        title _: String,
        remindAt: Date?,
        dateConfirmed: Bool,
        state: String
    ) async -> ReminderResult {
        let identifier = Self.identifier(for: actionID)
        // Replacement, completion, cancellation, and unconfirmed dates all remove the old request first.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])

        if state == "needs_date" {
            return ReminderResult(scheduled: false, message: "行动已保存为待补日期；确认具体时间后才会安排系统通知。")
        }
        guard state == "active" else {
            return ReminderResult(scheduled: false, message: state == "done" ? "行动已完成，系统提醒已取消。" : "行动已取消，系统提醒已取消。")
        }
        guard dateConfirmed else {
            return ReminderResult(scheduled: false, message: "行动已保存；确认提醒时间后才会安排系统通知。")
        }
        guard let remindAt else {
            return ReminderResult(scheduled: false, message: "行动已保存，未设置系统提醒。")
        }
        guard remindAt > Date() else {
            return ReminderResult(scheduled: false, message: "行动已保存，但提醒时间已过去；请设置未来时间。")
        }

        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    return ReminderResult(scheduled: false, message: "行动已保存，但系统通知未开启。")
                }
                settings = await center.notificationSettings()
            } catch {
                let failure = error as NSError
                logger.error("Notification authorization failed: \(failure.domain, privacy: .public) \(failure.code)")
                return ReminderResult(scheduled: false, message: "行动已保存，但系统通知授权失败。请稍后重试。")
            }
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return ReminderResult(scheduled: false, message: "行动已保存，但系统通知未开启。")
        }

        // No document text, file path, order details, or user-entered title appears on the lock screen.
        let content = UNMutableNotificationContent()
        content.title = "PersonalSpace 提醒"
        content.body = "你有一项待办行动需要处理。打开 PersonalSpace 查看详情。"
        content.sound = .default
        content.userInfo = ["actionID": actionID]

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: remindAt)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        guard let nextDate = trigger.nextTriggerDate(), nextDate > Date() else {
            return ReminderResult(scheduled: false, message: "行动已保存，但提醒时间已过去；请设置未来时间。")
        }

        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
            let message = settings.alertSetting == .enabled
                ? "行动已保存，系统提醒已安排。"
                : "行动已保存，提醒已安排；系统横幅未开启，请在通知中心查看。"
            return ReminderResult(scheduled: true, message: message)
        } catch {
            let failure = error as NSError
            logger.error("Notification scheduling failed: \(failure.domain, privacy: .public) \(failure.code)")
            return ReminderResult(scheduled: false, message: "行动已保存，但系统提醒安排失败。请稍后重试。")
        }
    }

    func pendingReminders() async -> [String: Date] {
        let requests = await center.pendingNotificationRequests()
        var pending: [String: Date] = [:]
        for request in requests {
            guard let actionID = request.content.userInfo["actionID"] as? String,
                  request.identifier == Self.identifier(for: actionID),
                  let trigger = request.trigger as? UNCalendarNotificationTrigger,
                  let date = trigger.nextTriggerDate() else { continue }
            pending[actionID] = date
        }
        return pending
    }

    func pendingActionIDs() async -> Set<String> {
        Set(await pendingReminders().keys)
    }

    func deliveredActionIDs() async -> Set<String> {
        let notifications = await center.deliveredNotifications()
        return Set(notifications.compactMap { notification in
            let request = notification.request
            guard let actionID = request.content.userInfo["actionID"] as? String,
                  request.identifier == Self.identifier(for: actionID) else { return nil }
            return actionID
        })
    }

    /// Reads current settings without prompting, including when the app starts.
    func permissionMessage() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return "系统通知尚未授权；保存已确认的未来提醒时会请求权限。"
        case .denied:
            return "系统通知未开启；行动仍会保存在待办中。"
        case .authorized, .provisional:
            return settings.alertSetting == .enabled
                ? "系统通知已开启。"
                : "系统通知已授权，横幅未开启；请在通知中心查看提醒。"
        @unknown default:
            return "无法确认系统通知权限；请在系统设置中检查 PersonalSpace 的通知。"
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let actionID = response.notification.request.content.userInfo["actionID"] as? String else { return }
        await MainActor.run { onOpenAction?(actionID) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return [] }
        var options: UNNotificationPresentationOptions = [.list]
        if settings.alertSetting == .enabled { options.insert(.banner) }
        if settings.soundSetting == .enabled { options.insert(.sound) }
        return options
    }
}
