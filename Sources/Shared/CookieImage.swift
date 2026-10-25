import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 带 cookie 的图片：登录后 cookie 固化成手动 token（manualCookie），
/// 裸 URLSession 不会自动带，这里手动补才拿得到 /api/img 的图。
struct CookieImage: View {
    let path: String
    var showSave = false
    @State private var img: UIImage?
    @State private var saved = false

    var body: some View {
        Group {
            if let img {
                VStack(spacing: 12) {
                    Image(uiImage: img).resizable().scaledToFit()
                    if showSave {
                        Button {
                            UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                            saved = true
                        } label: {
                            Label(saved ? "已保存到相册" : "保存到相册",
                                  systemImage: saved ? "checkmark.circle.fill"
                                                     : "square.and.arrow.down")
                                .font(.headline)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .padding(.bottom, 24)
                    }
                }
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
        guard !base.isEmpty,
              let u = URL(string: APIClient.join(base, path)) else { return }
        var r = URLRequest(url: u)
        if let c = UserDefaults.standard.string(forKey: "manualCookie"), !c.isEmpty {
            r.setValue(c, forHTTPHeaderField: "Cookie")
        }
        if let (data, resp) = try? await URLSession.shared.data(for: r),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            self.img = UIImage(data: data)
        }
    }
}
