#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct BowatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ChatLiveActivity()
    }
}

struct ChatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            // 锁屏样式
            LockScreenLiveView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            // 灵动岛
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(.purple)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.sessionName)
                            .font(.footnote.weight(.semibold))
                        if !context.state.text.isEmpty {
                            Text(context.state.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "brain.head.profile").foregroundStyle(.purple)
            } compactTrailing: {
                Text(context.state.status)
                    .font(.caption2)
                    .foregroundStyle(context.state.status == "已完成" ? .green : .purple)
            } minimal: {
                Image(systemName: "brain.head.profile").foregroundStyle(.purple)
            }
        }
    }
}

private struct LockScreenLiveView: View {
    let state: ChatActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title2).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("bowatch").font(.caption).foregroundStyle(.secondary)
                    Text(state.sessionName)
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(state.status)
                        .font(.caption)
                        .foregroundStyle(state.status == "已完成" ? .green : .purple)
                }
                if !state.text.isEmpty {
                    Text(state.text)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(14)
    }
}
#endif
