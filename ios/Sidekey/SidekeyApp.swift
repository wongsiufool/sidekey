import SwiftUI

@main
struct SidekeyApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// 调试/测试用的启动参数 —— **只在 DEBUG 构建里生效**。Release(上架)构建恒为空,
/// 所以任何 `--pintest` / `--reseed` / `--autotest` 等钩子在正式包里都彻底失效(纵深防御)。
/// 全 App 一律走这里读启动参数, 不再直接读 ProcessInfo.arguments。
enum DebugArgs {
    static var all: [String] {
        #if DEBUG
        return ProcessInfo.processInfo.arguments
        #else
        return []
        #endif
    }
    static func has(_ flag: String) -> Bool { all.contains(flag) }
}

/// 启动时先放欢迎页, 短暂展示后淡出露出主界面; 点一下可立即跳过。
private struct RootView: View {
    // UI 测试(--uitest)直达主界面, 不被欢迎页挡住; 正常启动照常先展示欢迎页。
    @State private var showWelcome = !DebugArgs.has("--uitest")

    var body: some View {
        ZStack {
            ContentView()
            if showWelcome {
                WelcomeView()
                    .transition(.opacity)
                    .zIndex(1)
                    .onTapGesture { dismiss() }
            }
        }
        .task {
            // 截图调试钩子: --welcomeonly 时停在欢迎页, 不自动淡出。
            guard !DebugArgs.has("--welcomeonly") else { return }
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            dismiss()
        }
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.5)) { showWelcome = false }
    }
}
