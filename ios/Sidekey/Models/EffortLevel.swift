import Foundation

/// Claude Code 的 Effort(思考力度)档位。通过 `/effort <级别>` 斜杠命令设置。
/// 级别: low / medium / high / xhigh / max,以及仅当前会话有效的 ultracode (= xhigh + 动态 workflow)。
///
/// 与 [[PermissionMode]] 一样,这是「用户主动选择后的本地显示状态」—— App 读不到 Claude Code 真实档位,
/// 只记住并显示用户最后设定的级别。
enum EffortLevel: Int, CaseIterable, Codable, Identifiable {
    case low = 1
    case medium = 2
    case high = 3
    case xhigh = 4
    case max = 5
    case ultracode = 6

    var id: Int { rawValue }

    /// `/effort` 命令的参数名。
    var cliName: String {
        switch self {
        case .low:       return "low"
        case .medium:    return "medium"
        case .high:      return "high"
        case .xhigh:     return "xhigh"
        case .max:       return "max"
        case .ultracode: return "ultracode"
        }
    }

    /// 面板标题。
    var title: String {
        switch self {
        case .low:       return "Low"
        case .medium:    return "Medium"
        case .high:      return "High"
        case .xhigh:     return "Extra high"
        case .max:       return "Max"
        case .ultracode: return "Ultracode"
        }
    }

    /// 中文说明 (面板副标题)。
    var detail: String {
        switch self {
        case .low:       return String(localized: "最快, 思考最少")
        case .medium:    return String(localized: "较快")
        case .high:      return String(localized: "均衡 (默认)")
        case .xhigh:     return String(localized: "更深思考")
        case .max:       return String(localized: "最深思考, 最慢")
        case .ultracode: return String(localized: "xhigh + 动态多智能体 (仅本会话)")
        }
    }

    /// 键面短名 (显示为「Effort · High」)。
    var shortLabel: String {
        switch self {
        case .low:       return "Low"
        case .medium:    return "Med"
        case .high:      return "High"
        case .xhigh:     return "X-High"
        case .max:       return "Max"
        case .ultracode: return "Ultra"
        }
    }
}
