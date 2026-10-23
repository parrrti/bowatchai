import SwiftUI

struct ContentView: View {
    @StateObject private var engine = ChatEngine()

    var body: some View {
        NavigationStack {
            content
                .task { await engine.boot() }
        }
    }

    @ViewBuilder private var content: some View {
        if engine.authed == true {
            SessionListView(engine: engine)
        } else if engine.authed == false {
            LoginView(engine: engine)
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
}

struct LoginView: View {
    @ObservedObject var engine: ChatEngine
    @State private var serverDraft = ""
    @State private var userDraft = ""
    @State private var pwDraft = ""

    var body: some View {
        Form {
            Section("服务器") {
                TextField("https://www.u3923374.nyat.app:59150", text: $serverDraft)
                    .keyboardType(.URL)
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
            }
            if !engine.bootError.isEmpty {
                Text("错误：\(engine.bootError)")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .navigationTitle("bowatch 登录")
    }
}

// ------------------------------------------------------------- 会话列表主页

struct SessionListView: View {
    @ObservedObject var engine: ChatEngine
    @State private var showSettings = false

    var body: some View {
        List(engine.sessions) { s in
            NavigationLink(value: s.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name).font(.body)
                    if let p = s.preview, !p.isEmpty {
                        Text(p).font(.footnote)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .navigationTitle(engine.persona.isEmpty ? "bowatch" : engine.persona)
        .navigationDestination(for: String.self) { sid in
            SessionDetailView(engine: engine, presetSid: sid)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { AccountSheet(engine: engine) } label: {
                    LetterAvatar(letter: engine.account?.display_name
                        ?? engine.account?.username ?? "?")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(engine: engine) }
    }
}

struct LetterAvatar: View {
    let letter: String
    var body: some View {
        Text(String((letter.first ?? "🧑").capitalized.first ?? "?"))
            .font(.footnote).bold()
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.accentColor))
    }
}

struct SettingsSheet: View {
    @ObservedObject var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
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
                                .font(.footnote)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                Section("流式传输") {
                    Picker("刷新间隔", selection: $engine.pollInterval) {
                        Text("1 秒").tag(1.0)
                        Text("1.5 秒").tag(1.5)
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
                }
                Section {
                    Button("刷新全部信息") { dismiss()
                        Task { await engine.boot(force: true) } }
                }
                if !engine.notice.isEmpty {
                    Section { Text(engine.notice).font(.footnote)
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
}

struct AccountSheet: View {
    @ObservedObject var engine: ChatEngine

    var body: some View {
        Form {
            Section("账户") {
                HStack(spacing: 12) {
                    LetterAvatar(letter: engine.account?.display_name
                        ?? engine.account?.username ?? "?")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.account?.display_name
                             ?? engine.account?.username ?? "未登录")
                        Text(engine.account?.username ?? "")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if engine.account?.admin == true {
                    Label("管理员", systemImage: "shield.fill")
                        .font(.footnote).foregroundStyle(.tint)
                }
                HStack {
                    Text("角色"); Spacer()
                    Text(engine.persona.isEmpty ? "Miyu" : engine.persona)
                        .foregroundStyle(.secondary)
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

// ------------------------------------------------------------- 聊天详情

enum DetailPage: Hashable {
    case image(Int)
    case think(Int)
}

struct SessionDetailView: View {
    @ObservedObject var engine: ChatEngine
    let presetSid: String
    @State private var draft = ""
    @State private var barHidden = false
    @State private var page: DetailPage?
    @FocusState private var focused: Bool
    private static let liveDot = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(engine.messages) { m in
                        Bubble(engine: engine, m: m, openPage: $page).id(m.id)
                    }
                    if engine.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(engine.liveText.isEmpty
                                 ? (engine.liveLine.isEmpty ? "…" : engine.liveLine)
                                 : engine.liveText)
                                .font(.body).foregroundStyle(.secondary)
                        }.id(Self.liveDot)
                    }
                    if !engine.notice.isEmpty {
                        Text(engine.notice).font(.footnote)
                            .foregroundStyle(.orange)
                            .onTapGesture { engine.notice = "" }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
            .onScrollPhaseChange { _, new in
                barHidden = (new == .tracking || new == .decelerating)
            }
            .onChange(of: engine.messages.count) { _, _ in
                proxy.scrollTo(engine.messages.last?.id ?? Self.liveDot,
                               anchor: .bottom)
            }
        }
        .navigationTitle(engine.sessions.first { $0.id == engine.sid }?.name
                         ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $page) { p in
            switch p {
            case .image(let mid):
                CookieImage(path: "/api/img?mid=\(mid)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .navigationTitle("图片")
                    .navigationBarTitleDisplayMode(.inline)
            case .think(let seq):
                ThinkPage(engine: engine, seq: seq)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !barHidden { sendBar }
        }
        .onAppear { if engine.sid != presetSid {
            Task { await engine.switchSession(presetSid) } } }
    }

    /// 方框+上三角：发送/终止一体，滚动时整个随 barHidden 藏起来
    private var sendBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("消息", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit {
                    let t = draft; draft = ""
                    Task { await engine.send(t) }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14))
            if engine.busy {
                Button { engine.stopRun() } label: {
                    Image(systemName: "stop.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.red.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                }.transition(.move(edge: .trailing))
            } else {
                Button { focused = true } label: {
                    Image(systemName: "arrowtriangle.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: barHidden)
        .animation(.snappy(duration: 0.2), value: engine.busy)
        .padding(8)
    }
}

struct Bubble: View {
    @ObservedObject var engine: ChatEngine
    let m: ChatEngine.Msg
    @Binding var openPage: DetailPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if m.role == "u" {
                HStack { Spacer()
                    Text(m.text)
                        .padding(10)
                        .background(Color.accentColor.opacity(0.85),
                                    in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
            } else {
                Text(m.text).font(.body).textSelection(.enabled)
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 14))
            }
            if !m.images.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(m.images.enumerated()), id: \.offset) { i, mid in
                        Button("[图\(i + 1)]") { openPage = .image(mid) }
                            .font(.footnote).buttonStyle(.bordered)
                    }
                }
            }
            if m.thinkN > 0 {
                Button("[思考·\(m.thinkN)字]") { openPage = .think(m.seq) }
                    .font(.footnote).buttonStyle(.bordered)
            }
            if let meta = m.meta, !meta.isEmpty {
                Text(meta).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ThinkPage: View {
    @ObservedObject var engine: ChatEngine
    let seq: Int
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "加载中…" : text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("思考")
        .navigationBarTitleDisplayMode(.inline)
        .task { text = await engine.think(seq: seq) }
    }
}

struct ModelSheet: View {
    @ObservedObject var engine: ChatEngine
    var body: some View {
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("跟随全局") { Task { await engine.setModel("") } }
            }
        }
        .onAppear { if engine.models.isEmpty { Task { await engine.loadModels() } } }
    }
}
