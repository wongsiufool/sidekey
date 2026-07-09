import Foundation

/// 可选键码 / 修饰键的目录, 给「按键编辑器」用。键码要和 server 的键名表对应。
enum KeyCatalog {
    struct Entry: Identifiable { var id: String { code }; let code: String; let label: String }
    struct Group: Identifiable { var id: String { name }; let name: String; let entries: [Entry] }

    /// 修饰键 (组合键用)。primary = mac的Cmd / 其它的Ctrl。
    static let modifiers: [Entry] = [
        .init(code: "primary", label: "⌘ / Ctrl  (主修饰键)"),
        .init(code: "shift", label: "Shift"),
        .init(code: "ctrl", label: "Control"),
        .init(code: "alt", label: "Option / Alt"),
        .init(code: "cmd", label: "Command / Win"),
    ]

    /// 区分左右的修饰键 (做 右Alt+右Shift 这类组合用)。
    static let modifiersLR: [Entry] = [
        .init(code: "rshift", label: "右 Shift"),
        .init(code: "ralt", label: "右 Option / Alt"),
        .init(code: "rctrl", label: "右 Control"),
        .init(code: "rcmd", label: "右 Command"),
        .init(code: "lshift", label: "左 Shift"),
        .init(code: "lalt", label: "左 Option / Alt"),
        .init(code: "lctrl", label: "左 Control"),
        .init(code: "lcmd", label: "左 Command"),
    ]

    static let groups: [Group] = [
        .init(name: "常用", entries: [
            .init(code: "enter", label: "Enter ⏎"), .init(code: "esc", label: "Esc"),
            .init(code: "space", label: "Space"), .init(code: "tab", label: "Tab"),
            .init(code: "backspace", label: "Backspace ⌫"), .init(code: "delete", label: "Delete"),
            .init(code: "fn", label: "Fn (触发, 仅 macOS 尽力)"),
        ]),
        .init(name: "方向 / 翻页", entries: [
            .init(code: "up", label: "↑ 上"), .init(code: "down", label: "↓ 下"),
            .init(code: "left", label: "← 左"), .init(code: "right", label: "→ 右"),
            .init(code: "home", label: "Home"), .init(code: "end", label: "End"),
            .init(code: "pageup", label: "Page Up"), .init(code: "pagedown", label: "Page Down"),
        ]),
        .init(name: "功能键", entries: (1...12).map { .init(code: "f\($0)", label: "F\($0)") }),
        .init(name: "媒体", entries: [
            .init(code: "vol_up", label: "🔊 音量 +"), .init(code: "vol_down", label: "🔉 音量 -"),
            .init(code: "mute", label: "🔇 静音"), .init(code: "play", label: "⏯ 播放 / 暂停"),
            .init(code: "next_track", label: "⏭ 下一曲"), .init(code: "prev_track", label: "⏮ 上一曲"),
        ]),
        .init(name: "字母", entries: "abcdefghijklmnopqrstuvwxyz".map { .init(code: String($0), label: String($0).uppercased()) }),
        .init(name: "数字", entries: (0...9).map { .init(code: "\($0)", label: "\($0)") }),
    ]
}
