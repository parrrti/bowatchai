import SwiftUI

struct WatchRootView: View {
    @StateObject private var engine = ChatEngine()
    @State private var serverDraft = ""
    @State private var userDraft = ""
    @State private var pwDraft = ""

    var body: some View {
        NavigationStack {
            content
                .onAppear {
                    if serverDraft.isEmpty { serverDraft = engine.serverURL }
                    Task { await engine.boot() }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if engine.authed == true {
            WatchChat(engine: engine)
        } else if engine.authed == false {
            Form {
                Section("服务器") {
                    TextField("地址", text: $serverDraft)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
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
        } else {
            VStack(spacing: 8) {
                ProgressView()
                if !engine.bootError.isEmpty {
                    Text("连不上：\(engine.bootError)").font(.caption2)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

struct WatchChat: View {
    @ObservedObject var engine: ChatEngine
    @State private var draft = ""
    @State private var showModels = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(engine.messages.suffix(6))) { m in
                    WatchBubble(engine: engine, m: m)
                }
                if engine.busy {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text(engine.liveText.isEmpty
                             ? (engine.liveLine.isEmpty ? "…" : engine.liveLine)
                             : engine.liveText)
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !engine.notice.isEmpty {
                    Text(engine.notice).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("bowatch")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Menu {
                    Button("新会话") { Task { await engine.newSession() } }
                    Button("刷新") { Task { await engine.boot(force: true) } }
                    Button("压缩上下文") { Task { await engine.compact(force: false) } }
                    Button("模型…") { Task { await engine.loadModels(); showModels = true } }
                    Button("登出", role: .destructive) { Task { await engine.logout() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showModels) {
            NavigationStack {
                List(engine.models, id: \.self) { full in
                    Button {
                        Task { await engine.setModel(full) }
                    } label: {
                        HStack {
                            Text(full).font(.caption2).lineLimit(1)
                            Spacer()
                            if engine.modelOverride == full {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                .toolbar {
                    Button("跟随全局") { Task { await engine.setModel("") } }
                }
                .navigationTitle("模型")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                TextField("消息", text: $draft)
                Button("发送") {
                    let t = draft; draft = ""
                    Task { await engine.send(t) }
                }
                .disabled(engine.busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct WatchBubble: View {
    @ObservedObject var engine: ChatEngine
    let m: ChatEngine.Msg
    @State private var think: String?
    @State private var showThink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if m.role == "u" {
                Text(m.text).font(.footnote).foregroundStyle(.tint)
            } else {
                if m.thinkN > 0 {
                    Button("思考·\(m.thinkN)字") { showThink = true }
                        .font(.caption2)
                        .sheet(isPresented: $showThink) {
                            ScrollView {
                                Text(think ?? "加载中…").font(.caption2)
                                    .onAppear {
                                        if think == nil {
                                            Task { think = await engine.think(seq: m.seq) }
                                        }
                                    }
                            }
                        }
                }
                Text(m.text).font(.footnote)
                if !m.images.isEmpty {
                    HStack {
                        ForEach(m.images.prefix(2), id: \.self) { mid in
                            CookieImage(path: "/api/img?mid=\(mid)")
                                .frame(width: 70, height: 70)
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
