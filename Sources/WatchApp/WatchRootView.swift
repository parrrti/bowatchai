import SwiftUI

struct WatchRootView: View {
    @StateObject private var engine = ChatEngine()

    var body: some View {
        NavigationStack {
            content
                .task { await engine.boot() }
        }
    }

    @ViewBuilder private var content: some View {
        if engine.authed == true {
            WatchSessionList(engine: engine)
        } else if engine.authed == false {
            WatchLoginView(engine: engine)
        } else {
            VStack(spacing: 8) {
                ProgressView()
                if !engine.bootError.isEmpty {
                    Text("连不上：\(engine.bootError)")
                        .font(.caption2).multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct WatchLoginView: View {
    @ObservedObject var engine: ChatEngine
    @State private var serverDraft = ""
    @State private var userDraft = ""
    @State private var pwDraft = ""

    var body: some View {
        Form {
            Section("服务器") {
                TextField("地址", text: $serverDraft)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onAppear { if serverDraft.isEmpty { serverDraft = engine.serverURL } }
            }
            Section("登录") {
                TextField("用户名", text: $userDraft)
                    .textInputAutocapitalization(.never)
                SecureField("密码", text: $pwDraft)
                Button("登录") {
                    engine.setServer(serverDraft)
                    Task { await engine.login(userDraft, pwDraft) }
                }
                if !engine.bootError.isEmpty {
                    Text("错误：\(engine.bootError)").font(.caption2)
                }
            }
        }
        .navigationTitle("bowatch")
    }
}

struct WatchSessionList: View {
    @ObservedObject var engine: ChatEngine
    @State private var showSettings = false

    var body: some View {
        List(engine.sessions) { s in
            NavigationLink(value: s.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.footnote)
                    if let p = s.preview, !p.isEmpty {
                        Text(p).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle(engine.persona.isEmpty ? "bowatch" : engine.persona)
        .navigationDestination(for: String.self) { sid in
            WatchChatDetail(engine: engine, presetSid: sid)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { WatchAccountSheet(engine: engine) } label: {
                    LetterAvatar(letter: engine.account?.display_name
                        ?? engine.account?.username ?? "?")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsBody(engine: engine, compact: true) }
        }
    }
}

struct WatchAccountSheet: View {
    @ObservedObject var engine: ChatEngine

    var body: some View {
        Form {
            Section("账户") {
                HStack(spacing: 8) {
                    LetterAvatar(letter: engine.account?.display_name
                        ?? engine.account?.username ?? "?")
                    Text(engine.account?.display_name
                         ?? engine.account?.username ?? "未登录")
                        .font(.footnote)
                }
                if engine.account?.admin == true {
                    Label("管理员", systemImage: "shield.fill")
                        .font(.caption2).foregroundStyle(.tint)
                }
                HStack {
                    Text("角色").font(.caption2)
                    Spacer()
                    Text(engine.persona.isEmpty ? "Miyu" : engine.persona)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("退出登录", role: .destructive) {
                    Task { await engine.logout() }
                }
            }
        }
        .navigationTitle("账户")
    }
}

/// iOS/手表共用的设置表单正文
struct SettingsBody: View {
    @ObservedObject var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    var compact = false

    var body: some View {
        Form {
            Section("模型") {
                NavigationLink {
                    ModelSheet(engine: engine)
                } label: {
                    HStack {
                        Text("选择模型")
                        Spacer()
                        Text(engine.modelOverride.isEmpty
                             ? "跟随全局" : engine.modelOverride)
                            .font(compact ? .caption2 : .footnote)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Section("流式传输") {
                Picker("刷新间隔", selection: $engine.pollInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("4 秒").tag(4.0)
                }
            }
            Section("对话") {
                Button("新建对话") { dismiss()
                    Task { await engine.newSession() } }
                Button("压缩对话") { dismiss()
                    Task { await engine.compact(force: false) } }
                Button("删除对话", role: .destructive) { confirmDelete = true }
                Button("刷新全部信息") { dismiss()
                    Task { await engine.boot(force: true) } }
            }
            if !engine.notice.isEmpty {
                Section { Text(engine.notice)
                        .font(compact ? .caption2 : .footnote)
                        .foregroundStyle(.orange)
                        .onTapGesture { engine.notice = "" } }
            }
        }
        .alert("删除当前对话？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { dismiss()
                Task { await engine.delSession() } }
        }
        .navigationTitle("设置")
        .toolbar { Button("完成") { dismiss() } }
    }
}

struct WatchChatDetail: View {
    @ObservedObject var engine: ChatEngine
    let presetSid: String
    @State private var draft = ""
    @State private var barHidden = false
    @State private var thinkSheetText: String?
    private static let liveDot = Int.max

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(engine.messages) { m in
                        WatchBubble(engine: engine, m: m,
                                    openThink: $thinkSheetText)
                    }
                    if engine.busy {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(engine.liveText.isEmpty
                                 ? (engine.liveLine.isEmpty ? "…" : engine.liveLine)
                                 : engine.liveText)
                                .font(.caption2).foregroundStyle(.secondary)
                        }.id(Self.liveDot)
                    }
                    if !engine.notice.isEmpty {
                        Text(engine.notice).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .onScrollPhaseChange { _, new in
                barHidden = (new == .tracking || new == .decelerating)
            }
            .onChange(of: engine.messages.count) { _, _ in
                proxy.scrollTo(engine.messages.last?.id ?? Self.liveDot,
                               anchor: .bottom)
            }
        }
        .navigationTitle("对话")
        .safeAreaInset(edge: .bottom) {
            if !barHidden {
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("消息", text: $draft)
                        .submitLabel(.done)
                        .onSubmit {
                            let t = draft; draft = ""
                            Task { await engine.send(t) }
                        }
                    if engine.busy {
                        Button { engine.stopRun() } label: {
                            Image(systemName: "stop.fill")
                                .frame(width: 30, height: 30)
                                .background(Color.red.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    } else {
                        Button { focusKeyboard() } label: {
                            Image(systemName: "arrowtriangle.up")
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .animation(.snappy(duration: 0.2), value: barHidden)
                .animation(.snappy(duration: 0.2), value: engine.busy)
                .padding(4)
            }
        }
        .sheet(item: Binding(
            get: { thinkSheetText.map { _ in ThinkBox() } },
            set: { if $0 == nil { thinkSheetText = nil } })) { _ in
            ScrollView {
                Text(thinkSheetText ?? "加载中…").font(.caption2)
                    .padding(.horizontal)
            }
            .task {
                if thinkSheetText == nil {
                    thinkSheetText = await engine.think(seq: pendingThinkSeq)
                }
            }
        }
        .onAppear { if engine.sid != presetSid {
            Task { await engine.switchSession(presetSid) } } }
    }

    @State private var pendingThinkSeq = 0
    @FocusState private var keyboardOn: Bool
    private func focusKeyboard() { keyboardOn = true }
}

struct ThinkBox: Hashable {}

struct WatchBubble: View {
    @ObservedObject var engine: ChatEngine
    let m: ChatEngine.Msg
    @Binding var openThink: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if m.role == "u" {
                Text(m.text).font(.footnote).foregroundStyle(.tint)
            } else {
                if m.thinkN > 0 {
                    Button("[思考·\(m.thinkN)字]") {
                        openThink = "加载中…"
                        Task {
                            openThink = await engine.think(seq: m.seq)
                        }
                    }.font(.caption2)
                }
                Text(m.text).font(.footnote)
                if !m.images.isEmpty {
                    HStack {
                        ForEach(Array(m.images.prefix(2).enumerated()),
                                id: \.offset) { i, mid in
                            NavigationLink(destination: {
                                CookieImage(path: "/api/img?mid=\(mid)")
                                    .frame(width: 160, height: 160)
                                    .background(Color.black)
                            }) {
                                Text("[图\(i + 1)]").font(.caption2)
                            }
                        }
                    }
                }
                if let meta = m.meta, !meta.isEmpty {
                    Text(meta).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
