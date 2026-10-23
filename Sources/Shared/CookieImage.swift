import SwiftUI

/// 带 cookie 的图片：URLSession.shared 同一 CookieStorage，天然带登录态
struct CookieImage: View {
    let path: String
    @State private var img: UIImage?

    var body: some View {
        Group {
            if let img {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 120, height: 90)
                    .overlay(ProgressView())
                    .task(id: path) { await load() }
            }
        }
    }

    private func load() async {
        let base = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        guard !base.isEmpty, let u = URL(string: base + "/watch" + path) else { return }
        if let (data, resp) = try? await URLSession.shared.data(from: u),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            self.img = UIImage(data: data)
        }
    }
}
