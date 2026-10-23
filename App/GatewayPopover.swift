import AppKit
import CcRouterCore
import SwiftUI

/// 菜单栏 popover：网关主开关（启停）+ Provider 列表（名称 + 各自启用开关），
/// 外加启动/保存错误的明示区与退出按钮；「设置…」打开设置窗口（任务 07）。
struct GatewayPopover: View {
    @State var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("网关", isOn: gatewayBinding)
                    .font(.headline)
                Spacer()
                Text("\(model.snapshot.listen.address):\(String(model.snapshot.listen.port))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if model.snapshot.providers.isEmpty {
                Text("尚未配置任何 Provider")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.providers, id: \.id) { provider in
                    Toggle(provider.name, isOn: providerBinding(provider.id))
                        .font(.body)
                }
            }

            Divider()

            HStack {
                Button("设置…") {
                    openWindow(id: "settings")
                }
                .font(.caption)
                Spacer()
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// 主开关的值跟随网关实际运行态；切换走 ConfigStore 持久化 + server start/stop。
    private var gatewayBinding: Binding<Bool> {
        Binding(
            get: { model.gatewayRunning },
            set: { newValue in
                Task { await model.setGateway(newValue) }
            }
        )
    }

    private func providerBinding(_ providerID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                model.snapshot.providers.first(where: { $0.id == providerID })?.enabled ?? false
            },
            set: { newValue in
                Task { await model.setProvider(providerID, enabled: newValue) }
            }
        )
    }
}
