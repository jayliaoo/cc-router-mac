import SwiftUI

/// 菜单栏 app 入口：静态图标（不区分状态，spec 24）+ popover（.window 样式
/// 以承载可交互的开关列表）。LSUIElement = true（不进 Dock）由 Info.plist 提供。
@main
struct CcRouterApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        MenuBarExtra("cc-router", systemImage: "arrow.left.arrow.right") {
            GatewayPopover(model: model)
        }
        .menuBarExtraStyle(.window)

        // 设置窗口（任务 07）：独立窗口，从 popover「设置…」打开。
        Window("cc-router 设置", id: "settings") {
            SettingsWindow(model: model)
        }
        .defaultSize(width: 680, height: 540)
    }
}
