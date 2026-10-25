import SwiftUI

@MainActor
final class ChatEngine: ObservableObject {
    struct Msg: Identifiable, Codable {
        var id: Int
        let role: String        // "u" / "a"
        let text: String
        let meta: String?
        let thinkN: Int
        let images: [Int]
        let seq: Int
    }

    @Published var authed: Bool?
    @Published var bootError = ""
    @Published var notice = ""
    @Published var serverURL: String
    @Published var persona = ""
    @Published var accountName = ""
    @Published var sid = ""
    @Published var sessions: [MWState.Sess] = []
    @Published var messages: [Msg] = []
    /// 本地拖动排序（UserDefaults 持久化；服务端不支持排序，仅本地生效）
    @Published private(set) var sessionOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "sessionOrder") ?? []
    @Published var running: Set<String> = []   // 正在生成的会话集合（每会话独立）
    @Published private var liveTexts: [String: String] = [:]
    @Published private var liveLines: [String: String] = [:]
    var busy: Bool { !running.isEmpty }
    var liveText: String { liveTexts[sid] ?? "" }
    var liveLine: String { liveLines[sid] ?? "" }
    @Published var ctx: MWCtx?
    @Published var models: [String] = []
    @Published var modelOverride = ""
    var api: APIClient
    private var booted = false
    @Published var account: MWState.Acct?
    @Published var pollInterval: Double { didSet {
        UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
    } }
    @Published var manualCookie: String? { didSet {
        if let c = manualCookie {
            UserDefaults.standard.set(c, forKey: "manualCookie")
        } else {
            UserDefaults.standard.removeObject(forKey: "manualCookie")
        }
        api.extraCookie = manualCookie
    } }
    private var nextID = 1
    private var pollTasks: [String: Task<Void, Never>] = [:]

    init() {
        let saved = UserDefaults.standard.string(forKey: "serverURL")
            ?? "https://www.u3923374.nyat.app:59150"
        serverURL = saved
        api = APIClient(baseURL: saved)
        pollInterval = UserDefaults.standard.double(forKey: "pollInterval")
        if pollInterval < 0.5 { pollInterval = 2.0 }
        manualCookie = UserDefaults.standard.string(forKey: "manualCookie")
        api.extraCookie = manualCookie
    }

    private func next() -> Int { let i = nextID; nextID += 1; return i }

    func applyManualCookie(_ v: String) { manualCookie = v }

    // MARK: - 通知 / Live Activity（仅 iOS，watchOS 编译时跳过）
    private func noteDone(_ title: String, _ body: String) {
        #if os(iOS)
        Notifier.shared.notify(title: title, body: body)
        #endif
    }
    private func liveStart(_ name: String) {
        #if os(iOS)
        Notifier.shared.startLive(sessionName: name)
        #endif
    }
    private func liveUpdate(_ status: String, _ text: String) {
        #if os(iOS)
        Notifier.shared.updateLive(status: status, text: text)
        #endif
    }
    private func liveEnd(_ status: String, _ text: String) {
        #if os(iOS)
        Notifier.shared.endLive(finalStatus: status, finalText: text)
        #endif
    }

    func stopRun(_ id: String) {
        pollTasks[id]?.cancel(); pollTasks[id] = nil
        if running.contains(id) {
            running.remove(id)
            liveTexts[id] = ""; liveLines[id] = "已停止"
        }
    }

    func stopRun() { stopRun(sid) }

    func setServer(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        serverURL = s
        UserDefaults.standard.set(s, forKey: "serverURL")
        api = APIClient(baseURL: s)
    }

    func boot(force: Bool = false) async {
        guard !booted || force else { return }
        booted = true
        bootError = ""
        loadCache()
        do {
            let st = try await api.state()
            authed = true
            persona = st.persona ?? ""
            accountName = st.account?.display_name ?? st.account?.username ?? ""
            account = st.account
            sessions = st.sessions ?? []
            sid = st.current ?? ""
            ctx = st.ctx
            await loadHistory()
            saveCache()
        } catch APIError.unauthorized {
            authed = false
        } catch {
            authed = nil
            bootError = error.localizedDescription
            loadCache()  // 断网也直接亮出本地缓存
        }
    }

    func login(_ user: String, _ pw: String) async {
        bootError = ""
        do {
            try await api.login(user, pw)
            // miyu下发的是会话级cookie，杀进程即丢——当场固化成手动token
            if let base = URL(string: serverURL),
               let c = HTTPCookieStorage.shared.cookies(for: base)?
                   .first(where: { $0.name.lowercased().contains("session") }) {
                manualCookie = "\(c.name)=\(c.value)"
            }
            booted = false
            await boot(force: true)
        } catch {
            authed = false
            bootError = error.localizedDescription
        }
    }

    /// 输入服务器地址时即时存盘（未登录也保留）
    func persistDraft(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("://") { s = "https://" + s }
        UserDefaults.standard.set(s, forKey: "serverURL")
    }

    func logout() async {
        try? await api.logout()
        manualCookie = nil
        authed = false
        booted = false
        sessions = []
        messages = []
        sid = ""
        account = nil
        try? UserDefaults.standard.removeObject(forKey: "bowatch.cache")
    }

    func loadHistory() async {
        guard !sid.isEmpty else { return }
        do {
            let h = try await api.history(sid: sid, n: 40)
            messages = h.messages.map {
                Msg(id: next(), role: $0.role, text: $0.text, meta: $0.meta,
                    thinkN: $0.think_n ?? 0, images: $0.images ?? [],
                    seq: $0.seq ?? 0)
            }
            saveCache()
        } catch APIError.unauthorized { authed = false }
        catch { bootError = error.localizedDescription }
    }

    func switchSession(_ id: String) async {
        sid = id
        messages = []
        await loadHistory()
        await refreshMeta()
    }

    func send(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !running.contains(sid) else {
            notice = "这个会话还在生成中，先停下或等它说完"
            return
        }
        let sid0 = sid
        running.insert(sid0)
        liveTexts[sid0] = ""; liveLines[sid0] = "思考中…"
        liveStart(sessions.first { $0.id == sid0 }?.name ?? "对话")
        let task = Task { [weak self] in
            guard let self else { return }
            var activeSid = sid0
            do {
                let (usedSid, since) = try await self.api.send(text, sid: sid0)
                activeSid = usedSid
                self.running.insert(usedSid)
                if self.sid == usedSid {
                    self.messages.append(Msg(id: self.next(), role: "u", text: text,
                                             meta: nil, thinkN: 0, images: [], seq: 0))
                    self.saveCache()
                }
                var waited = 0.0
                while waited < 420, !Task.isCancelled {
                    try await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1e9))
                    waited += self.pollInterval
                    let st = try await self.api.status(sid: usedSid, since: since)
                    switch st.state {
                    case "done":
                        self.liveTexts[usedSid] = ""; self.liveLines[usedSid] = ""
                        if self.sid == usedSid {
                            self.messages.append(Msg(id: self.next(), role: "a",
                                                     text: st.text ?? "（空回复）",
                                                     meta: st.meta,
                                                     thinkN: st.think_n ?? 0,
                                                     images: st.images ?? [],
                                                     seq: st.seq ?? 0))
                            self.saveCache()
                        }
                        self.ctx = st.ctx
                        await self.refreshMeta()
                        self.liveEnd("已完成", st.text ?? "")
                        self.noteDone("回复完成", String((st.text ?? "").prefix(60)))
                        self.running.remove(usedSid)
                        self.pollTasks[usedSid] = nil
                        return
                    case "running":
                        if let t = st.text {
                            self.liveTexts[usedSid] = t
                            self.liveUpdate("生成中", t)
                        }
                        if let l = st.live, !l.isEmpty { self.liveLines[usedSid] = l }
                    default:
                        if (self.liveLines[usedSid] ?? "").isEmpty {
                            self.liveLines[usedSid] = "等待中…"
                        }
                    }
                }
                if !Task.isCancelled {
                    throw APIError.http("回复超时")
                } else {
                    return  // stopRun() 自己收尾
                }
            } catch APIError.unauthorized {
                self.authed = false
                self.running.remove(activeSid)
                self.pollTasks[activeSid] = nil
            } catch is CancellationError {
                return
            } catch {
                self.liveLines[activeSid] = "出错了：\(error.localizedDescription)"
                self.running.remove(activeSid)
                self.pollTasks[activeSid] = nil
            }
        }
        pollTasks[sid0] = task
    }

    func newSession() async {
        do {
            let s = try await api.newSession()
            await switchSession(s.id)
        } catch APIError.unauthorized { authed = false }
        catch { notice = "\(error.localizedDescription)" }
    }

    /// 按本地拖动顺序排序的会话列表
    var orderedSessions: [MWState.Sess] {
        let idx = Dictionary(uniqueKeysWithValues:
            sessionOrder.enumerated().map { ($1, $0) })
        return sessions.sorted {
            (idx[$0.id] ?? Int.max) < (idx[$1.id] ?? Int.max)
        }
    }

    func moveSession(from source: IndexSet, to destination: Int) {
        var arr = orderedSessions.map(\.id)
        arr.move(fromOffsets: source, offsetTo: destination)
        sessionOrder = arr
        UserDefaults.standard.set(arr, forKey: "sessionOrder")
    }

    func delSession() async {
        await delSession(sid)
    }

    func delSession(_ id: String) async {
        guard !id.isEmpty else { return }
        do {
            _ = try await api.delSession(id)
            notice = "会话已删"
            noteDone("会话已删", "")
            await boot(force: true)
        } catch APIError.unauthorized { authed = false }
        catch {
            notice = "删除失败：\(error.localizedDescription)"
        }
    }

    func compactSession(_ id: String) async {
        notice = "压缩中…"
        do {
            let r = try await api.compact(sid: id, force: false)
            var msg = r.compacted ? "已压缩" : "不需要压缩"
            if let d = r.detail, !d.isEmpty { msg += "：" + String(d.suffix(120)) }
            notice = msg
            noteDone("压缩完成", msg)
            if id == sid { await refreshCtx() }
        } catch APIError.unauthorized { authed = false }
        catch { notice = "压缩失败：\(error.localizedDescription)" }
    }

    func loadModels() async {
        do {
            let m = try await api.modelsList(sid: sid)
            models = m.models ?? []
            modelOverride = m.currentLabel
        } catch APIError.unauthorized { authed = false }
        catch { notice = "\(error.localizedDescription)" }
    }

    func setModel(_ full: String) async {
        do {
            try await api.setModel(sid: sid, full)
            modelOverride = full
            notice = full.isEmpty ? "已恢复跟随全局" : "模型已设：\(full)"
            models = []
        } catch APIError.unauthorized { authed = false }
        catch { notice = "换模型失败：\(error.localizedDescription)" }
    }

    func compact(force: Bool) async {
        notice = force ? "强制压缩中，可能要几分钟…" : "压缩中…"
        do {
            let r = try await api.compact(sid: sid, force: force)
            var msg = r.compacted ? "已压缩" : "不需要压缩"
            if let d = r.detail, !d.isEmpty {
                msg += "：" + String(d.suffix(120))
            }
            notice = msg
            noteDone("压缩完成", msg)
            await refreshCtx()
        } catch APIError.unauthorized { authed = false }
        catch { notice = "压缩失败：\(error.localizedDescription)" }
    }

    func refreshCtx() async { ctx = try? await api.ctxInfo(sid: sid) }

    func refreshMeta() async {
        await refreshCtx()
        if let m = try? await api.modelsCurrent(sid: sid) {
            modelOverride = m.currentLabel
        }
    }

    func think(seq: Int) async -> String {
        (try? await api.think(sid: sid, seq: seq).think) ?? "（取不到）"
    }

    private func loadCache() {
        guard let d = UserDefaults.standard.data(forKey: "bowatch.cache"),
              let c = try? JSONDecoder().decode(Cache.self, from: d) else { return }
        sessions = c.sessions
        sid = c.current
        messages = c.messages
        nextID = c.nextID
        persona = c.persona
        account = c.account
        accountName = c.account?.display_name ?? c.account?.username ?? ""
        ctx = c.ctx
        modelOverride = c.modelOverride
    }

    func saveCache() {
        let c = Cache(sessions: sessions, current: sid, messages: messages,
                      nextID: nextID, persona: persona, account: account,
                      ctx: ctx, modelOverride: modelOverride)
        if let d = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(d, forKey: "bowatch.cache")
        }
    }

    private struct Cache: Codable {
        var sessions: [MWState.Sess]
        var current: String
        var messages: [Msg]
        var nextID: Int
        var persona: String
        var account: MWState.Acct?
        var ctx: MWCtx?
        var modelOverride: String
    }
}
