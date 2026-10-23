import SwiftUI

struct ContentView: View {
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
            ChatView(engine: engine)
        } else if engine.authed == false {
            loginView
        } else {
            VStack(spacing: 10) {
                ProgressView("连接中…")
                if !engine.bootError.isEmpty {
                    Text("连不上：\(engine.bootError)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("改服务器地址") { engine.authed = false }
                }
            }
        }
    }

    private var loginView: some View {
        Form {
            Section("服务器") {
                TextField("https://www.u3923374.nyat.app:59150", text: $serverDraft)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Section("登录") {
                TextField("用户名", text: $userDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $pwDraft)
                Button("登录") {
                    engine.setServer(serverDraft)
                    Task { await engine.login(userDraft, pwDraft) }
                }
            }
            if !engine.bootError.isEmpty {
                Text("错误：\(engine.bootError)")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("bowatch 登录")
    }
}

struct ChatView: View {
    @ObservedObject var engine: ChatEngine
    @State private var draft = ""
    @State private var showModels = false
    @State private var camStamp = 0
    private static let liveDot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.messages) { m in
                        Bubble(engine: engine, m: m).id(m.id)
                    }
                    if engine.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(engine.liveText.isEmpty
                                 ? (engine.liveLine.isEmpty ? "…" : engine.liveLine)
                                 : engine.liveText)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.id(Self.liveDot)
                    }
                    if !engine.notice.isEmpty {
                        Text(engine.notice)
                            .font(.footnote).foregroundStyle(.orange)
                            .onTapGesture { engine.notice = "" }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .onChange(of: engine.messages.count) { _, _ in
                proxy.scrollTo(engine.messages.last?.id ?? Self.liveDot, anchor: .bottom)
            }
        }
        .navigationTitle(engine.persona.isEmpty ? "bowatch" : engine.persona)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    if !engine.sessions.isEmpty {
                        Section("会话记录") {
                            ForEach(engine.sessions) { s in
                                Button(String(s.name)) {
                                    Task { await engine.switchSession(s.id) }
                                }
                            }
                        }
                    }
                    Section {
                        Button("新会话") { Task { await engine.newSession() } }
                        Button("刷新") { Task { await engine.boot(force: true) } }
                        Button("模型…") {
                            Task { await engine.loadModels(); showModels = true }
                        }
                        Button("压缩上下文") { Task { await engine.compact(force: false) } }
                        Button("强制压缩") { Task { await engine.compact(force: true) } }
                        Button("摄像头快照") { camStamp += 1 }
                        Button("登出（\(engine.accountName)）", role: .destructive) {
                            Task { await engine.logout() }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(alignment: .bottom) {
                TextField("消息", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14))
                Button {
                    let t = draft; draft = ""
                    Task { await engine.send(t) }
                } label: { Image(systemName: "paperplane.fill") }
                    .disabled(engine.busy || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
        .safeAreaInset(edge: .top) {
            ctxLine
        }
        .sheet(isPresented: $showModels) { ModelSheet(engine: engine) }
        .fullScreenCover(isPresented: Binding(
            get: { camStamp > 0 }, set: { if !$0 { camStamp = 0 } })) {
            CamSheet(engine: engine, stamp: camStamp)
        }
    }

    private var ctxLine: some View {
        HStack {
            if let c = engine.ctx {
                Text(String(format: "上下文 %d/%d（%.0f%%）",
                            c.used, c.window, c.ratio * 100))
            } else if !engine.modelOverride.isEmpty {
                Text(engine.modelOverride).lineLimit(1)
            }
            Spacer()
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.horizontal).padding(.vertical, 2)
        .background(.bar)
    }
}

struct Bubble: View {
    @ObservedObject var engine: ChatEngine
    let m: ChatEngine.Msg
    @State private var think: String?
    @State private var thinkOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if m.role == "a", m.thinkN > 0 {
                DisclosureGroup(isExpanded: $thinkOpen) {
                    Text(think ?? "加载中…")
                        .font(.caption).foregroundStyle(.secondary)
                        .onAppear {
                            if think == nil {
                                Task { think = await engine.think(seq: m.seq) }
                            }
                        }
                } label: {
                    Text("思考·\(m.thinkN)字")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if m.role == "u" {
                HStack { Spacer()
                    Text(m.text)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            } else {
                Text(m.text).textSelection(.enabled)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14))
            }
            if !m.images.isEmpty {
                HStack(spacing: 6) {
                    ForEach(m.images, id: \.self) { mid in
                        CookieImage(path: "/api/img?mid=\(mid)")
                            .frame(maxWidth: 220, maxHeight: 160)
                    }
                }
            }
            if let meta = m.meta, !meta.isEmpty {
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ModelSheet: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
        NavigationStack {
            List(engine.models, id: \.self) { full in
                Button {
                    Task { await engine.setModel(full) }
                } label: {
                    HStack {
                        Text(full).font(.footnote).lineLimit(1)
                        Spacer()
                        if engine.modelOverride == full {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
            .navigationTitle("模型 \(engine.models.count)")
            .toolbar {
                Button("跟随全局") {
                    Task { await engine.setModel("") }
                }
            }
        }
    }
}

struct CamSheet: View {
    let engine: ChatEngine
    let stamp: Int
    var body: some View {
        CookieImage(path: "/api/camimg?t=\(stamp)")
            .ignoresSafeArea()
    }
}
