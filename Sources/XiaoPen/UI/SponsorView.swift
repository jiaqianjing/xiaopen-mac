import SwiftUI
import AppKit

/// "支持小喷": WeChat and Alipay codes bundled with the app.
struct SponsorView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("支持小喷").font(.title2.bold())
            Text("小喷是一个人业余维护的开源项目。如果它帮到了你，欢迎请作者喝杯咖啡。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 20) {
                code("SponsorWeChat", title: "微信")
                code("SponsorAlipay", title: "支付宝")
            }
            HStack {
                Link("给项目点个 Star", destination: AppInfo.homepage)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func code(_ name: String, title: String) -> some View {
        VStack(spacing: 8) {
            if let image = Bundle.module.image(forResource: name) {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Text(title).font(.callout)
        }
    }
}
