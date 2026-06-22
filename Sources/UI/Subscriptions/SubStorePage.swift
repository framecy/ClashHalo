import SwiftUI

struct SubStorePage: View {
    @StateObject private var engine = SubStoreEngine.shared

    private var webURL: URL? {
        let backend = engine.backendURL
        let urlString = "https://sub-store.vercel.app/subs?api=\(backend)"
        return URL(string: urlString)
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "Sub-Store", desc: "高级订阅转换工具")

            VStack(spacing: 32) {
                Spacer()

                // 图标
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)

                VStack(spacing: 16) {
                    Text("Sub-Store 订阅管理")
                        .font(.title2.bold())

                    if engine.isRunning {
                        Text("后端运行中: \(engine.backendURL)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("正在启动后端...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    FeatureRow(icon: "link", text: "管理多个订阅源")
                    FeatureRow(icon: "arrow.triangle.branch", text: "订阅格式转换")
                    FeatureRow(icon: "slider.horizontal.3", text: "自定义规则和分组")
                    FeatureRow(icon: "clock.arrow.circlepath", text: "自动更新订阅")
                }
                .frame(maxWidth: 360)

                Button {
                    if let url = webURL {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("在浏览器中打开 Sub-Store", systemImage: "safari")
                        .font(.body.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.orange)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 360)
                .disabled(!engine.isRunning)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
        .onAppear {
            engine.start()
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.orange)
                .frame(width: 20)
            Text(text)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
