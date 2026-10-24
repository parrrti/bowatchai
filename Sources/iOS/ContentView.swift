import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var engine = ChatEngine()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .task { await engine.boot() }
        }
        .onChange(of: scenePhase) { _, s in
            if s == .active, engine.authed == true {
                Task { await engine.boot(force: true) }
            }
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
    @State private var showFallback = false

    var body: some View {
        Form {
                Section("服务器") {
                TextField("https://…nyat.app:59150 或 http://192.168.1.186/watch_ai", text: $serverDraft)
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Text("备用登录：双击此处")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { showFallback = true }
            .padding(.bottom, 6)
        }
        .sheet(isPresented: $showFallback) {
            FallbackLogin(engine: engine)
        }
    }
}

// -------------------------------------------- 备用方案：WebUI手动登录读token

struct SafariLogin: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct FallbackLogin: View {
    @ObservedObject var engine: ChatEngine
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var webUrl: URL?
    @State private var hint = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("MiYu WebUI 地址，如 http://192.168.1.186:8300",
                          text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if let u = webUrl {
                    SafariLogin(url: u)
                    Button {
                        grabCookie(from: u)
                    } label: {
                        Label("我已登录，读取token", systemImage: "key")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("打开登录页") {
                        var s = urlText.trimmingCharacters(in: .whitespaces)
                        while s.hasSuffix("/") { s.removeLast() }
                        if !s.contains("://") { s = "http://" + s }
                        webUrl = URL(string: s)
                    }
                    .disabled(urlText.isEmpty)
                }
                if !hint.isEmpty {
                    Text(hint).font(.footnote).foregroundStyle(.red)
                }
                Text("在网页里登录 miyu 账号后点「读取token」，App 会存下会话凭证直连。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
            .navigationTitle("备用登录")
            .toolbar { Button("关闭") { dismiss() } }
        }
    }

    private func grabCookie(from url: URL) {
        guard let c = HTTPCookieStorage.shared.cookies(for: url)?
            .first(where: { $0.name.lowercased().contains("session") }) else {
            hint = "还没读到登录cookie——请确认已在上方网页里登录成功"
            return
        }
        engine.applyManualCookie("\(c.name)=\(c.value)")
        dismiss()
        Task { await engine.boot(force: true) }
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
    private static let liveDot = Int.max

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
        .navigationTitle(titleText)
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

    private var titleText: String {
        engine.sessions.first { $0.id == engine.sid }?.name ?? "对话"
    }

    /// 方框+上三角：发送/终止一体，滚动时整个随 barHidden 藏起来
    private var sendBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("消息", text: $draft)
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

