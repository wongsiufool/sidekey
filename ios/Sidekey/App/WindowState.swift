import SwiftUI

/// 窗口级状态 (§4.7): 每个窗口自己的当前电脑、模式、页、子页。M1 只有一个窗口, M5 起每个窗口一份。
/// 窗口被系统回收后再恢复时, 用 `@SceneStorage` 里存的字符串还原, 目标已被删除时按 `resolve` 的规则回退。
@MainActor
final class WindowState: ObservableObject {
    /// 窗口自己的标识: 连接池按它登记使用者和前台状态。
    let id = UUID()
    @Published var computerID: UUID
    @Published var modeID: UUID
    @Published var layerID: String
    /// 当前子页的「第一可见行」: 形态切换 / 窗口变化后子页数量会变, 按它停在包含这一行的子页 (§3.6)。
    @Published var subpageRow: Int = 0
    /// 手机横屏 B 类放不下时用户选的区 (§3.5): 只显示按键 / 只显示触控板。
    @Published var singleZone: SingleZone = .keys

    init(computerID: UUID, modeID: UUID, layerID: String = "base") {
        self.computerID = computerID
        self.modeID = modeID
        self.layerID = layerID
    }

    /// 新窗口的默认值: 「最近使用」的电脑和模式 (存档里的 currentComputerID / currentModeID 只剩这个用途)。
    convenience init(defaultsFrom store: LayoutStore) {
        self.init(computerID: store.currentComputerID, modeID: store.currentModeID)
    }

    // MARK: - 恢复规则 (§4.7): 电脑不在了 → 最近使用的电脑; 模式不在了 → 这台电脑的第一个模式; 页不在了 → 第 1 页

    struct Resolved: Equatable { var computerID: UUID; var modeID: UUID; var layerID: String }

    /// 纯函数, 便于单测。`recent*` 是「最近使用」的电脑 / 模式。
    nonisolated static func resolve(computerRaw: String?, modeRaw: String?, layerRaw: String?,
                        computers: [Computer], recentComputerID: UUID, recentModeID: UUID) -> Resolved {
        let computer = computerRaw.flatMap(UUID.init(uuidString:)).flatMap { id in computers.first { $0.id == id } }
            ?? computers.first { $0.id == recentComputerID } ?? computers[0]
        let savedModeID = modeRaw.flatMap(UUID.init(uuidString:))
        var mode = savedModeID.flatMap { id in computer.modes.first { $0.id == id } }
        if mode == nil {
            if savedModeID != nil {
                // 窗口存的模式已经被删: 这台电脑的第一个模式 (§4.7)
                mode = computer.modes.first
            } else {
                // 没存过 (新窗口 / 首次): 取这台电脑上次用的模式, 再退回第一个
                mode = computer.lastModeID.flatMap { id in computer.modes.first { $0.id == id } } ?? computer.modes.first
            }
        }
        let resolvedMode = mode ?? computer.modes[0]
        let layer = layerRaw.flatMap { raw in resolvedMode.layers.contains { $0.id == raw } ? raw : nil }
            ?? resolvedMode.layers.first?.id ?? "base"
        return Resolved(computerID: computer.id, modeID: resolvedMode.id, layerID: layer)
    }

    func apply(_ r: Resolved) {
        computerID = r.computerID; modeID = r.modeID; layerID = r.layerID
    }
}
