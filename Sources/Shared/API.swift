import Foundation

enum APIError: Error {
    case unauthorized
    case http(String)
    case badURL
}

struct MWCtx: Codable { let used: Int; let window: Int; let ratio: Double }
struct MWCtxWrap: Codable { let ctx: MWCtx? }

struct MWState: Codable {
    struct Sess: Decodable, Identifiable {
        let id: String; let name: String
        let preview: String?; let mode: String?
    }
    struct Acct: Codable {
        let username: String?; let display_name: String?; let admin: Bool?
    }
    let auth: Int?
    let current: String?
    let ctx: MWCtx?
    let persona: String?
    let sessions: [Sess]?
    let account: Acct?
}

struct MWStatus: Codable {
    let state: String
    let text: String?
    let live: String?
    let meta: String?
    let ctx: MWCtx?
    let think_n: Int?
    let seq: Int?
    let images: [Int]?
}

struct MWHistory: Codable {
    struct M: Codable {
        let role: String; let text: String
        let meta: String?; let think_n: Int?
        let images: [Int]?; let seq: Int?
    }
    let messages: [M]
}

struct MWModels: Codable {
    struct Ov: Codable { let provider_id: String; let model: String }
    let models: [String]?
    let current: [Ov]?
    var currentLabel: String {
        current?.first.map { "\($0.provider_id)/\($0.model)" } ?? ""
    }
}

struct MWThink: Codable { let think: String }
struct MWNewSession: Codable { let id: String; let name: String }
struct MWDel: Codable {
    struct FB: Codable { let id: String; let name: String }
    let ok: Int?
    let fallback: FB?
}
struct MWCompact: Codable { let compacted: Bool; let detail: String? }

final class APIClient {
    static let prefix = "/watch"
    private(set) var baseURL: String

    init(baseURL: String) { self.baseURL = baseURL }

    func url(_ path: String) -> URL? {
        URL(string: baseURL + Self.prefix + path)
    }

    private func req(_ path: String, method: String = "GET",
                     body: [String: Any]? = nil, timeout: Double = 30) throws -> URLRequest {
        guard let u = url(path) else { throw APIError.badURL }
        var r = URLRequest(url: u)
        r.httpMethod = method
        r.timeoutInterval = timeout
        if let body {
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func raw(_ path: String, method: String = "GET",
                     body: [String: Any]? = nil,
                     timeout: Double = 30) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(
            for: req(path, method: method, body: body, timeout: timeout))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else { throw APIError.http("HTTP \(code)") }
        return data
    }

    private func dec<T: Decodable>(_ type: T.Type, _ path: String,
                                   method: String = "GET", body: [String: Any]? = nil,
                                   timeout: Double = 30) async throws -> T {
        let data = try await raw(path, method: method, body: body, timeout: timeout)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.http("响应解析失败") }
    }

    // ---- 认证 -------------------------------------------------------
    func login(_ user: String, _ pw: String) async throws {
        let (data, resp) = try await URLSession.shared.data(
            for: req("/api/login", method: "POST",
                     body: ["username": user, "password": pw], timeout: 20))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw APIError.http("登录失败 HTTP \(code) \(data.count > 0 ? "（检查账号密码）" : "")")
        }
    }

    func logout() async throws {
        let r = try req("/api/logout", method: "POST")
        _ = try? await URLSession.shared.data(for: r)
        if let list = HTTPCookieStorage.shared.cookies {
            list.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }

    // ---- 会话 -------------------------------------------------------
    func state() async throws -> MWState { try await dec(MWState.self, "/api/state") }

    func send(_ text: String, sid: String) async throws -> (String, Int) {
        struct R: Codable { let sid: String; let since: Int }
        var payload: [String: Any] = ["text": text]
        if !sid.isEmpty { payload["sid"] = sid }
        let r: R = try await dec(R.self, "/api/send", method: "POST", body: payload)
        return (r.sid, r.since)
    }

    private func qenc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    func status(sid: String, since: Int) async throws -> MWStatus {
        try await dec(MWStatus.self, "/api/status?sid=\(qenc(sid))&since=\(since)")
    }

    func history(sid: String, n: Int = 40) async throws -> MWHistory {
        try await dec(MWHistory.self, "/api/history?sid=\(qenc(sid))&n=\(n)")
    }

    func newSession() async throws -> MWNewSession {
        try await dec(MWNewSession.self, "/api/new-session", method: "POST", body: [:])
    }

    func delSession(_ sid: String) async throws -> MWDel {
        try await dec(MWDel.self, "/api/delsession", method: "POST",
                      body: ["sid": sid], timeout: 60)
    }

    // ---- 模型 / 压缩 / 思考 ------------------------------------------
    func modelsList(sid: String) async throws -> MWModels {
        try await dec(MWModels.self, "/api/models?sid=\(qenc(sid))")
    }

    func modelsCurrent(sid: String) async throws -> MWModels {
        try await dec(MWModels.self, "/api/models?sid=\(qenc(sid))&lite=1")
    }

    func setModel(sid: String, _ full: String) async throws {
        let parts = full.split(separator: "/", maxSplits: 1).map(String.init)
        var body: [String: Any] = ["sid": sid]
        if parts.count == 2 { body["pid"] = parts[0]; body["model"] = parts[1] }
        _ = try await raw("/api/models", method: "POST", body: body, timeout: 60)
    }

    func compact(sid: String, force: Bool) async throws -> MWCompact {
        try await dec(MWCompact.self, "/api/compact", method: "POST",
                      body: ["sid": sid, "force": force],
                      timeout: force ? 600 : 60)
    }

    func ctxInfo(sid: String) async throws -> MWCtx? {
        try await dec(MWCtxWrap.self, "/api/ctx?sid=\(qenc(sid))").ctx
    }

    func think(sid: String, seq: Int) async throws -> MWThink {
        try await dec(MWThink.self, "/api/think?sid=\(qenc(sid))&seq=\(seq)")
    }
}
