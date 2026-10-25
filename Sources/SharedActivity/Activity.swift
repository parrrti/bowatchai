#if os(iOS)
import ActivityKit

/// 灵动岛/锁屏实时活动的数据模型（iOS App 与 Widget Extension 共用）
struct ChatActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String   // "思考中" / "生成中" / "已完成"
        var text: String     // 实时正文（截断展示）
        var sessionName: String
    }

    var startedAt: Date
}
#endif
