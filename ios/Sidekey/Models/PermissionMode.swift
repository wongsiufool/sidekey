import Foundation

/// Claude Code 的权限模式。真实切换机制是 **Shift+Tab 循环**(不是 ⌘⇧M+数字 —— 那在 Claude Code 里不存在)。
///
/// 始终可用的核心循环只有 3 档: default(Ask) → acceptEdits → plan。
/// auto / bypass 仅在会话额外启用后才进入 Shift+Tab 循环 (见 requiresSetup / setupNote):
///   - auto: 需 Team/Enterprise 管理员开启 + Opus/Sonnet 4.6+。
///   - bypass: 需用 --dangerously-skip-permissions 一类参数启动 Claude Code。
///
/// 这是「用户主动选择后的本地显示状态」—— App 读不到 Claude Code 真实当前模式, 只记住并显示用户最后设定的档位。
enum PermissionMode: Int, CaseIterable, Codable, Identifiable {
    case ask = 1
    case acceptEdits = 2
    case plan = 3
    case auto = 4
    case bypass = 5

    var id: Int { rawValue }

    /// 在 Claude Code 真实 Shift+Tab 循环里的位置 (0 起)。真实顺序: default→acceptEdits→plan→bypass→auto。
    var cycleRank: Int {
        switch self {
        case .ask:         return 0
        case .acceptEdits: return 1
        case .plan:        return 2
        case .bypass:      return 3
        case .auto:        return 4
        }
    }

    /// 始终可用的 3 档核心循环 (default/acceptEdits/plan)。
    var isCore: Bool { self == .ask || self == .acceptEdits || self == .plan }

    /// 需在 Claude Code 会话额外启用才会进入 Shift+Tab 循环 (auto / bypass)。
    var requiresSetup: Bool { !isCore }

    var setupNote: String {
        switch self {
        case .auto:   return String(localized: "需 Team/Enterprise 管理员开启 + Opus/Sonnet 4.6+")
        case .bypass: return String(localized: "需用 --dangerously-skip-permissions 启动 Claude Code")
        default:      return ""
        }
    }

    /// 英文标题 (与 Claude Code 一致)。
    var title: String {
        switch self {
        case .ask:         return "Ask permissions"
        case .acceptEdits: return "Accept edits"
        case .plan:        return "Plan mode"
        case .auto:        return "Auto mode"
        case .bypass:      return "Bypass permissions"
        }
    }

    /// 中文说明 (面板副标题)。
    var detail: String {
        switch self {
        case .ask:         return String(localized: "每次需要授权时询问")
        case .acceptEdits: return String(localized: "自动接受文件编辑")
        case .plan:        return String(localized: "先规划, 再执行")
        case .auto:        return String(localized: "自动处理常规操作")
        case .bypass:      return String(localized: "跳过所有权限确认")
        }
    }

    /// 键面短名 (显示为「权限 · Ask」)。
    var shortLabel: String {
        switch self {
        case .ask:         return "Ask"
        case .acceptEdits: return "Accept"
        case .plan:        return "Plan"
        case .auto:        return "Auto"
        case .bypass:      return "Bypass"
        }
    }

    /// 启用 extras 时的完整循环 (5 档); 否则只有 3 档核心。按 cycleRank 排序。
    static func cycle(includingExtras extras: Bool) -> [PermissionMode] {
        let all: [PermissionMode] = extras ? [.ask, .acceptEdits, .plan, .bypass, .auto]
                                           : [.ask, .acceptEdits, .plan]
        return all
    }

    /// 从 current 切到 self 需要按几次 Shift+Tab (按当前循环长度取模)。current 不在循环里时按 0 处理。
    func shiftTabPresses(from current: PermissionMode, includingExtras extras: Bool) -> Int {
        let len = extras ? 5 : 3
        let cur = current.cycleRank < len ? current.cycleRank : 0
        let tgt = cycleRank < len ? cycleRank : cur
        return ((tgt - cur) % len + len) % len
    }
}
