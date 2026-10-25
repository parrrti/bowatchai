#if os(iOS)
import Foundation
import UserNotifications
import ActivityKit

@MainActor
final class Notifier {
    static let shared = Notifier()
    private init() {}

    private var activity: Activity<ChatActivityAttributes>?

    /// 启动时请求通知权限（App 启动调一次）
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - 本地通知（回答完成/操作完成都推）
    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Live Activity（灵动岛/锁屏）
    func startLive(sessionName: String, status: String = "思考中") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // 同一时刻只留一个活动
        endLive()
        let attrs = ChatActivityAttributes(startedAt: Date())
        let state = ChatActivityAttributes.ContentState(status: status,
                                                        text: "",
                                                        sessionName: sessionName)
        activity = try? Activity.request(attributes: attrs, contentState: state,
                                         pushType: nil)
    }

    func updateLive(status: String, text: String) {
        guard let activity else { return }
        let state = ChatActivityAttributes.ContentState(status: status,
                                                        text: text,
                                                        sessionName: activity.content.state.sessionName)
        Task { await activity.update(using: state) }
    }

    func endLive(finalStatus: String = "已完成", finalText: String = "") {
        guard let activity else { return }
        let state = ChatActivityAttributes.ContentState(status: finalStatus,
                                                        text: finalText,
                                                        sessionName: activity.content.state.sessionName)
        Task {
            // .immediate：完成即刻收起灵动岛，不停留
            await activity.end(using: state, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
#endif
