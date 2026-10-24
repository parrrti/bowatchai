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
    @Published var busy = false
    @Published var runningSid = ""     // 正在生成的会话，防止串会话显示
    @Published var liveText = ""
    @Published var liveLine = ""
    @Published var ctx: MWCtx?
    @Published var models: [String] = []
    @Published var modelOverride = ""
    var api: APIClient
    private var booted = false
    @Published var account: MWState.Acct?
    @Published var pollInterval: Double
    @Published var manualCookie: String? { didSet {
        if let c = manualCookie {
            UserDefaults.standard.set(c, forKey: "manualCookie")
        } else {
            UserDefaults.standard.removeObject(forKey: "manualCookie")
        }
        api.extraCookie = manualCookie
    } }
    private var nextID = 1
    private var pollTask: Task<Void, Never>?

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

    func stopRun() {
        pollTask?.cancel(); pollTask = nil
        if busy { busy = false; runningSid = ""; liveLine = "已停止" }
    }

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
            booted = false
            await boot(force: true)
        } catch {
            authed = false
            bootError = error.localizedDescription
        }
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
        guard !busy else {
            notice = "有会话还在生成中，先停下或等它说完"
            return
        }
        guard !text.isEmpty else { return }
        busy = true; liveText = ""; liveLine = "发送中…"
        pollTask?.cancel()
        let sid0 = sid
        runningSid = sid0
        pollTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (usedSid, since) = try await self.api.send(text, sid: sid0)
                self.runningSid = usedSid
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
                        self.liveText = ""; self.liveLine = ""
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
                        self.busy = false
                        self.runningSid = ""
                        return
                    case "running":
                        if let t = st.text { self.liveText = t }
                        if let l = st.live, !l.isEmpty { self.liveLine = l }
                    default:
                        if self.liveLine.isEmpty { self.liveLine = "等待中…" }
                    }
                }
                if !Task.isCancelled {
                    throw APIError.http("回复超时")
                } else {
                    return  // stopRun() 自己收尾
                }
            } catch APIError.unauthorized {
                self.authed = false
                self.busy = false
                self.runningSid = ""
            } catch is CancellationError {
                return
            } catch {
                self.liveLine = "出错了：\(error.localizedDescription)"
                self.busy = false
                self.runningSid = ""
            }
        }
    }

    func newSession() async {
        do {
            let s = try await api.newSession()
            await switchSession(s.id)
        } catch APIError.unauthorized { authed = false }
        catch { notice = "\(error.localizedDescription)" }
    }

    func delSession() async {
        guard !sid.isEmpty else { return }
        do {
            _ = try await api.delSession(sid)
            notice = "会话已删"
            await boot(force: true)
        } catch APIError.unauthorized { authed = false }
        catch {
            notice = "删除失败：\(error.localizedDescription)"
        }
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
