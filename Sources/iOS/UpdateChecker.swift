import Foundation

struct UpdateInfo {
    let latest: String
    let url: String
}

enum UpdateChecker {
    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 有新版才返回 info，否则 nil
    static func check() async -> UpdateInfo? {
        guard let u = URL(string:
            "https://api.github.com/repos/parrrti/bowatchai/releases/latest")
        else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String
        else { return nil }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let cur = currentVersion()
        // .numeric：0.0.9 < 0.0.31 这种逐段数字比较
        if latest.compare(cur, options: .numeric) == .orderedDescending {
            let html = j["html_url"] as? String
            return UpdateInfo(latest: latest,
                              url: html ?? "https://github.com/parrrti/bowatchai/releases")
        }
        return nil
    }
}
