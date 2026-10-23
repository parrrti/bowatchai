import SwiftUI

/// 首字母头像：苹果风格圆形
struct LetterAvatar: View {
    let letter: String
    var body: some View {
        Text(String(letter.prefix(1)).uppercased())
            .font(.footnote).bold()
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.accentColor))
    }
}

/// 模型选择列表（懒加载）
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
