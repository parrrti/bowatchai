import SwiftUI

@MainActor
final class ChatEngine: ObservableObject {
    struct Msg: Identifiable {
        let id = UUID()
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
    @Published var liveText = ""
    @Published var liveLine = ""
    @Published var ctx: MWCtx?
    @Published var models: [String] = []
    @Published var modelOverride = ""
    var api: APIClient
    private var booted = false

    init() {
        serverURL = UserDefaults.standard.string(forKey: "serverURL")
            ?? "https://www.u3923374.nyat.app:59150"
        api = APIClient(baseURL: serverURL)
    }

    func setServer(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        serverURL = s
        UserDefaults.standard.set(s, forKey: "serverURL")
        api = APIClient(baseURL: s)
    }

    func boot(force: Bool = false) async {
        guard !booted || force else { return }
        booted = true
        bootError = ""
        do {
            let st = try await api.state()
            authed = true
            persona = st.persona ?? ""
            accountName = st.account?.display_name ?? st.account?.username ?? ""
            sessions = st.sessions ?? []
            sid = st.current ?? ""
            ctx = st.ctx
            await loadHistory()
        } catch APIError.unauthorized {
            authed = false
        } catch {
            authed = nil
            bootError = error.localizedDescription
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
        authed = false
        booted = false
        sessions = []
        messages = []
        sid = ""
    }

    func loadHistory() async {
        guard !sid.isEmpty else { return }
        do {
            let h = try await api.history(sid: sid, n: 40)
            messages = h.messages.map {
                Msg(role: $0.role, text: $0.text, meta: $0.meta,
                    thinkN: $0.think_n ?? 0, images: $0.images ?? [],
                    seq: $0.seq ?? 0)
            }
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
        guard !text.isEmpty, !busy else { return }
        busy = true; liveText = ""; liveLine = "发送中…"
        defer { busy = false }
        do {
            let (usedSid, since) = try await api.send(text, sid: sid)
            sid = usedSid
            messages.append(Msg(role: "u", text: text, meta: nil,
                                thinkN: 0, images: [], seq: 0))
            var waited = 0.0
            while waited < 420 {
                try await Task.sleep(nanoseconds: 1_500_000_000)
                waited += 1.5
                let st = try await api.status(sid: sid, since: since)
                switch st.state {
                case "done":
                    liveText = ""; liveLine = ""
                    messages.append(Msg(role: "a", text: st.text ?? "（空回复）",
                                        meta: st.meta, thinkN: st.think_n ?? 0,
                                        images: st.images ?? [], seq: st.seq ?? 0))
                    ctx = st.ctx
                    await refreshMeta()
                    return
                case "running":
                    if let t = st.text { liveText = t }
                    if let l = st.live, !l.isEmpty { liveLine = l }
                default:
                    if liveLine.isEmpty { liveLine = "等待中…" }
                }
            }
            throw APIError.http("回复超时")
        } catch APIError.unauthorized {
            authed = false
        } catch {
            liveLine = "出错了：\(error.localizedDescription)"
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
}
