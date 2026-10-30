import Foundation

/// 一个按键的定义。布局采用「网格坐标」模型: 每个键从 (col,row) 开始,
/// 占据 colSpan×rowSpan 个格子。整套布局数据驱动 —— 编辑器只改这里。
struct KeyCap: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var label: String                  // 屏幕上显示的文字, 如 "Enter"
    var code: String = ""              // 发给电脑的键码, 如 "enter" (见 server 键名表)
    var mods: [String] = []            // 修饰键, 如 ["primary"] = mac的Cmd / 其它的Ctrl
    var col: Int = 0                   // 左上角所在列 (0 起)
    var row: Int = 0                   // 左上角所在行 (0 起)
    var colSpan: Int = 1               // 横向占几格
    var rowSpan: Int = 1               // 纵向占几格
    var kind: Kind = .normal           // 普通键 / 切层键 / 录音键
    var targetLayer: String? = nil     // kind == .layer 时, 切到哪一层
    var tint: KeyTint? = nil           // 功能分组色 (nil = 跟随类型默认; 主要给「活泼」风格分组上色)
    var sendText: String? = nil        // 非空 = 点这个键直接「粘贴一段文字」(斜杠指令用, 如 /init)
    var icon: String? = nil            // SF Symbol 名 (键面 = 图标 + 英文; nil = 只显示文字)
    var winApp: String? = nil          // kind == .window: 绑定窗口所属 App (如 "Paseo")
    var winTitle: String? = nil        // kind == .window: 绑定窗口标题 (聚焦时按 app+title 重新查找)
    var winId: Int? = nil              // kind == .window: 窗口编码 (快速命中; 窗口重开会变, 仅作快路径)
    var slot: Int? = nil               // kind == .agentSlot: 显示 client.agentSessions 里第几个会话 (状态看板 6 灯)。必须是可选: 旧存档没有这个键, 非可选会让整份存档解码失败

    /// normal=普通/组合键 · layer=切层键 · record=录音(语言输入)
    /// permission=Claude Code 权限模式键 (点击展开权限面板, 键面实时显示当前模式)
    /// effort=Claude Code Effort 档位键 (点击展开 Effort 面板, 键面实时显示当前档位)
    /// trackpad=触控板区域 (占一整块网格; 正常模式下触摸=触控板手势, 编辑器里可拖拽/缩放)
    /// mouseButton=鼠标键 (code "left"=左键: 按住=down 松开=up, 轻点即单击+可拖; code "right"=右键: 点=右键单击)
    /// window=窗口快捷键 (绑定电脑上一个窗口: 点键=把该窗口切到最前; 跨 App 通用 —— Paseo 对话/终端/浏览器都行)
    /// agentSlot=状态灯槽 (自动显示正在跑的第 slot 个 Claude Code 会话 + 项目名; 灯色=忙橙/待绿/闲灰; 点击用 claude://resume 深链在 Claude 桌面版打开该会话)
    /// unknown=本版不认识的类型 (来自更新版本的存档): 灰色占位键, 不能发出按键; 整键原始数据在 rawUnknown 里原样保留 (见 KeyCapCoding.swift)。
    enum Kind: String, Codable, CaseIterable { case normal, layer, record, permission, effort, trackpad, mouseButton, window, agentSlot, unknown }
    var rawUnknown: UnknownKeyData? = nil   // kind == .unknown 时的整键原始数据; 其余情况恒为 nil
}

/// 本版不认识的键的原始数据: 原始 JSON 树 (数字保留原文) + 解码时的位置快照 (保存时只在位置真的被编辑过才改写位置字段)。
struct UnknownKeyData: Hashable {
    var tree: JSONValue
    var col: Int, row: Int, colSpan: Int, rowSpan: Int
    /// 解码时的 id 快照: 复制键换了新 id 时 (≠ 快照), 保存要把新 id 写进原始数据, 否则重载后副本又变回原键的 id。
    var id: UUID? = nil
}

/// 按键的「功能分组色」。在「活泼」风格下给不同功能的键上不同色; 其它风格弱化为中性。
/// success/danger = 语义色 (确认绿 / 回退红), 各风格都生效 (minimal 仍中性)。
enum KeyTint: String, Codable, CaseIterable {
    case accent, coral, mint, sky, lavender, amber, neutral, success, danger
}

/// 一层键盘布局 = 固定列数的网格 + 落在网格里的键。
struct KeyLayer: Identifiable, Codable, Equatable {
    var id: String                     // "base", "more", ...
    var columns: Int = 8               // 网格列数 (每层可不同, 可加减)
    var keys: [KeyCap]

    /// 网格行数 = 最靠下的键的底边 (至少 1 行, 供渲染算总高)。
    /// 加法饱和: 读到异常大的坐标也不会整数溢出崩溃 (存档校验会把这类数据挡在恢复流程里, 这里是最后一道保险)。
    var rowCount: Int { max(1, keys.map { k in let (v, o) = k.row.addingReportingOverflow(k.rowSpan); return o ? Int.max : v }.max() ?? 0) }
}

/// 内置默认布局 (网格版)。base 常用键 + more 功能层, 各 8 列。
enum DefaultLayout {
    static let columns = 8

    static func makeBase() -> KeyLayer {
        KeyLayer(id: "base", columns: columns, keys: [
            KeyCap(label: "Esc", code: "esc", col: 0, row: 0, tint: .neutral),
            KeyCap(label: "Tab", code: "tab", col: 1, row: 0, tint: .neutral),
            KeyCap(label: "⌫", code: "backspace", col: 2, row: 0, tint: .neutral),
            KeyCap(label: "⌘C", code: "c", mods: ["primary"], col: 3, row: 0, tint: .sky),
            KeyCap(label: "⌘V", code: "v", mods: ["primary"], col: 4, row: 0, tint: .sky),
            KeyCap(label: "⌘Z", code: "z", mods: ["primary"], col: 5, row: 0, tint: .sky),
            KeyCap(label: "⌘A", code: "a", mods: ["primary"], col: 6, row: 0, tint: .sky),
            KeyCap(label: "Enter", code: "enter", col: 7, row: 0, rowSpan: 2, tint: .coral),   // 竖向加高示例
            KeyCap(label: "←", code: "left", col: 0, row: 1, tint: .mint),
            KeyCap(label: "↑", code: "up", col: 1, row: 1, tint: .mint),
            KeyCap(label: "↓", code: "down", col: 2, row: 1, tint: .mint),
            KeyCap(label: "→", code: "right", col: 3, row: 1, tint: .mint),
            KeyCap(label: "F1", code: "f1", col: 4, row: 1, tint: .amber),
            KeyCap(label: "F2", code: "f2", col: 5, row: 1, tint: .amber),
            KeyCap(label: "F3", code: "f3", col: 6, row: 1, tint: .amber),
            KeyCap(label: "Space", code: "space", col: 0, row: 2, colSpan: 7),   // 页用滑动切换, 不再放「更多」切层键
        ])
    }

    static func makeMore() -> KeyLayer {
        KeyLayer(id: "more", columns: columns, keys: [
            KeyCap(label: "F1", code: "f1", col: 0, row: 0, tint: .amber),
            KeyCap(label: "F2", code: "f2", col: 1, row: 0, tint: .amber),
            KeyCap(label: "F3", code: "f3", col: 2, row: 0, tint: .amber),
            KeyCap(label: "F4", code: "f4", col: 3, row: 0, tint: .amber),
            KeyCap(label: "F5", code: "f5", col: 4, row: 0, tint: .amber),
            KeyCap(label: "F6", code: "f6", col: 5, row: 0, tint: .amber),
            KeyCap(label: "F7", code: "f7", col: 6, row: 0, tint: .amber),
            KeyCap(label: "F8", code: "f8", col: 7, row: 0, tint: .amber),
            KeyCap(label: "🔉", code: "vol_down", col: 0, row: 1, tint: .sky),
            KeyCap(label: "🔊", code: "vol_up", col: 1, row: 1, tint: .sky),
            KeyCap(label: "🔇", code: "mute", col: 2, row: 1, tint: .sky),
            KeyCap(label: "⏯", code: "play", col: 3, row: 1, tint: .mint),
            KeyCap(label: "F11", code: "f11", col: 4, row: 1, tint: .amber),
            KeyCap(label: "F12", code: "f12", col: 5, row: 1, tint: .amber),
        ])
    }

    static func makeDefault() -> [KeyLayer] { [makeBase(), makeMore()] }

    /// 纯展示 fallback (id 无所谓)。
    static var base: KeyLayer { makeBase() }
}

/// 出厂内置的两个模式: 「Vibe Coding」(单页触控板, 默认) + 「vibecoding键盘模式」(快捷键)。
/// 新装 / 迁移时种入; Vibe 在前 = 默认选中。各层用 12 列网格便于对齐。
enum BuiltinModes {
    /// 内置布局版本: 每次改内置布局就 +1, 旧存档会在启动时自动重种到最新 (保留电脑/连接)。
    /// v4: Vibe Coding 改为「主页 3×3 + 第二页 4×4」编码控制面 + Claude Code 权限模式键。
    /// v5: Effort 键改为 .effort 种类 (点击弹 Effort 面板 + 键面跟踪档位)。
    /// v6: 工作模式新增第二页 = 整块触控板 (.trackpad)。
    /// v7: 「工作模式」改造为单页「鼠标模式」(主页整块触控板, 去掉办公键页)。
    /// v8: 触控板拆成「纯触摸面」+ 独立「左键/右键」按钮(.mouseButton); 触控板不再自带按钮条。
    /// v9: Vibe Coding 拆成单页(只留触控板页); 原第二页快捷键重做为独立「vibecoding键盘模式」。
    /// v10: 强制统一阵容(不论新老/是否编辑过) —— Vibe 只保留第一页 + 删除「鼠标模式」; 仅留 Vibe + vibecoding键盘模式。
    /// v11: 新增内置模式「Codex Micro」—— 对位 OpenAI Codex Micro 宏键盘真机排布(方形 4×4: 四角特色控件 + 6 颗辉光状态键 + 底部宽麦克风)。追加式种入 (addMissingBuiltins), 不动用户已有模式。
    /// v12: 新增内置模式「笔记本键盘」(§4.9, 类型标识 .laptopKeyboard)。追加式种入, 按类型标识判断有没有 (不靠名字), 不动用户已有模式。
    static let version = 12

    /// 顺序即默认顺序: 第一个 (Vibe) 为默认模式。鼠标模式 v10 起不再内置 (mouse() 仅供迁移识别/兼容旧检测器)。
    static func makeAll() -> [Mode] { [vibe(), vibecodingKbd(), codexMicro(), laptopKeyboard()] }

    static func vibe() -> Mode { Mode(name: "Vibe Coding", layers: [vibeBase()]) }
    static func vibecodingKbd() -> Mode { Mode(name: "vibecoding键盘模式", layers: [vibecodingKbdBase()]) }
    static func codexMicro() -> Mode { Mode(name: "Codex Micro", layers: [codexMicroBase()]) }
    static func mouse() -> Mode { Mode(name: "鼠标模式", layers: [mouseBase()]) }
    /// 「笔记本键盘」(§4.9): 键位固定 (附录键表), 不进网格编辑器、没有页和子页, 不生成大屏键位。
    /// 存一页空的 base 只是为了让旧版本 (认不出类型标识的) 读到的是一个合法的空模式。
    static func laptopKeyboard() -> Mode { Mode(name: "笔记本键盘", layers: [KeyLayer(id: "base", columns: 12, keys: [])], kind: .laptopKeyboard) }

    /// 鼠标模式: 单页。上方一整块触控板(只管触摸), 下方独立的左键/右键按钮。
    private static func mouseBase() -> KeyLayer {
        KeyLayer(id: "base", columns: 12, keys: [
            KeyCap(label: "触控板", col: 0, row: 0, colSpan: 12, rowSpan: 5, kind: .trackpad),
            KeyCap(label: "左键", code: "left", col: 0, row: 5, colSpan: 6, kind: .mouseButton),
            KeyCap(label: "右键", code: "right", col: 6, row: 5, colSpan: 6, kind: .mouseButton),
        ])
    }

    /// Vibe 第一页 (id "base"): 用户自定的出厂默认布局 (2026-06-24 由用户手机布局固化)。
    /// 触控板(占5行) + 第5行 左键/SPACE/Backspace + 第6行 Typeless(左Ctrl)/ENTER/ESC。
    private static func vibeBase() -> KeyLayer {
        KeyLayer(id: "base", columns: 12, keys: [
            KeyCap(label: "触控板", col: 0, row: 0, colSpan: 12, rowSpan: 5, kind: .trackpad),
            KeyCap(label: "左键", code: "left", col: 0, row: 5, colSpan: 4, kind: .mouseButton),
            KeyCap(label: "SPACE", code: "space", col: 4, row: 5, colSpan: 4),
            KeyCap(label: "Backspace", code: "backspace", col: 8, row: 5, colSpan: 4),
            // Typeless 触发键: 贴 Typeless logo, 一眼看出是「触发 Typeless 语音」而非神秘的纯 Ctrl 键。
            // 实际行为仍是发左 Ctrl(电脑端 Typeless app 据此启动语音; 没装 Typeless 则按它无反应 —— 编辑器里有说明)。审计 M-7。
            KeyCap(label: "Typeless", mods: ["lctrl"], col: 0, row: 6, colSpan: 4, tint: .accent, icon: "typeless"),
            KeyCap(label: "ENTER", code: "enter", col: 4, row: 6, colSpan: 4),
            KeyCap(label: "ESC", code: "esc", col: 8, row: 6, colSpan: 4),
        ])
    }

    /// 「vibecoding键盘模式」出厂布局 (v9 新增): 单页 12 列, 由原 Vibe 第二页重做而来。
    /// 行1 ⌘ 组合(左 Command) · 行2 斜杠命令 · 行3 Typeless(同第一页风格) + 退格/Esc/回车。
    private static func vibecodingKbdBase() -> KeyLayer {
        KeyLayer(id: "base", columns: 12, keys: [
            // 行1: ⌘ 组合 (primary = Mac ⌘ / 其它平台 Ctrl, 跨平台自动适配)
            KeyCap(label: "⌘A", code: "a", mods: ["primary"], col: 0, row: 0, colSpan: 3),
            KeyCap(label: "⌘C", code: "c", mods: ["primary"], col: 3, row: 0, colSpan: 3),
            KeyCap(label: "⌘V", code: "v", mods: ["primary"], col: 6, row: 0, colSpan: 3),
            KeyCap(label: "⌘Z", code: "z", mods: ["primary"], col: 9, row: 0, colSpan: 3),
            // 行2: 斜杠命令 (点一下 = 粘贴命令文字并回车)
            cmd("/usage", col: 0, row: 1, span: 3),
            cmd("/btw", col: 3, row: 1, span: 3),
            cmd("/compact", col: 6, row: 1, span: 3),
            cmd("/clear", col: 9, row: 1, span: 3),
            // 行3: Typeless(贴 logo, 实发左 Ctrl, 同第一页风格) + 退格/Esc/回车
            KeyCap(label: "Typeless", mods: ["lctrl"], col: 0, row: 2, colSpan: 3, tint: .accent, icon: "typeless"),
            KeyCap(label: "Backspace", code: "backspace", col: 3, row: 2, colSpan: 3),
            KeyCap(label: "Esc", code: "esc", col: 6, row: 2, colSpan: 3),
            KeyCap(label: "Enter", code: "enter", col: 9, row: 2, colSpan: 3, tint: .accent),
        ])
    }

    /// 「Codex Micro」出厂布局 (v11 新增): 对位 OpenAI Codex Micro 宏键盘的真机排布 —— 方形 4×4 pad。
    /// 真机四角是特色控件(左上触摸盘 / 右上摇杆 / 左下旋钮), 中间两排 6 颗彩色发光键 = agent 状态灯, 底部一条宽麦克风键。
    /// Sidekey 没有触摸盘/摇杆/旋钮/状态灯这些硬件, 按「位置对位、就近取义」映射(不是 1:1 复刻硬件, 是复刻布局骨架):
    ///   行0: [权限(⇧Tab 循环, 呼应触摸盘切态)] · [状态灯0] · [状态灯1] · [触控板(≈右上摇杆)]
    ///   行1: 状态灯 2–5 —— [灯2][灯3][灯4][灯5]
    ///   行2: 命令键 —— [/usage(≈⚡)] [Enter(≈✓, success 绿)] [Esc(≈✕, danger 红)] [/resume(≈⤢)]
    ///   行3: [Effort(≈左下旋钮, 调思考档)] · [语音(≈底部宽麦克风, 占 2 格)] · [Backspace(≈右下 >_ 角)]
    /// 中间 6 颗 = 真机 6 颗发光键 → Sidekey「状态灯槽」(.agentSlot): 自动显示正在跑的前 6 个 Claude Code 会话,
    /// 灯色随状态(忙橙/待绿/闲灰), 点击聚焦运行它的终端窗口(按项目名匹配)。无需绑定, 数据来自电脑端周期推送。4 列网格。
    private static func codexMicroBase() -> KeyLayer {
        KeyLayer(id: "base", columns: 4, keys: [
            // 行0: 左上触摸角 / 状态灯 0-1 / 右上摇杆角
            KeyCap(label: "权限", col: 0, row: 0, kind: .permission),
            KeyCap(label: "", col: 1, row: 0, kind: .agentSlot, slot: 0),
            KeyCap(label: "", col: 2, row: 0, kind: .agentSlot, slot: 1),
            KeyCap(label: "触控板", col: 3, row: 0, kind: .trackpad),
            // 行1: 状态灯 2-5
            KeyCap(label: "", col: 0, row: 1, kind: .agentSlot, slot: 2),
            KeyCap(label: "", col: 1, row: 1, kind: .agentSlot, slot: 3),
            KeyCap(label: "", col: 2, row: 1, kind: .agentSlot, slot: 4),
            KeyCap(label: "", col: 3, row: 1, kind: .agentSlot, slot: 5),
            // 行2: 命令键 (Enter=success 绿✓ / Esc=danger 红✕, 均走自带图标脸)
            KeyCap(label: "/usage", col: 0, row: 2, tint: .coral, sendText: "/usage"),
            KeyCap(label: "Enter", code: "enter", col: 1, row: 2, tint: .success),
            KeyCap(label: "Esc", code: "esc", col: 2, row: 2, tint: .danger),
            KeyCap(label: "/resume", col: 3, row: 2, tint: .coral, sendText: "/resume"),
            // 行3: 旋钮→Effort / 宽麦克风→语音(.record 原生听写) / 右下角→Backspace
            KeyCap(label: "Effort", col: 0, row: 3, kind: .effort),
            KeyCap(label: "语音", col: 1, row: 3, colSpan: 2, kind: .record, tint: .accent),
            KeyCap(label: "Backspace", code: "backspace", col: 3, row: 3, tint: .neutral),
        ])
    }

    /// 旧「工作模式」办公布局。**现仅用于迁移识别**: 判断旧工作模式是否未编辑, 以便安全改名为「鼠标模式」。
    static func legacyWorkBase() -> KeyLayer {
        KeyLayer(id: "base", columns: 12, keys: [
            KeyCap(label: "复制", code: "c", mods: ["primary"], col: 0, row: 0, colSpan: 4),
            KeyCap(label: "粘贴", code: "v", mods: ["primary"], col: 4, row: 0, colSpan: 4),
            KeyCap(label: "保存", code: "s", mods: ["primary"], col: 8, row: 0, colSpan: 4),
            KeyCap(label: "全选", code: "a", mods: ["primary"], col: 0, row: 1, colSpan: 4),
            KeyCap(label: "查找", code: "f", mods: ["primary"], col: 4, row: 1, colSpan: 4),
            KeyCap(label: "打印", code: "p", mods: ["primary"], col: 8, row: 1, colSpan: 4),
            KeyCap(label: "撤销", code: "z", mods: ["primary"], col: 0, row: 2, colSpan: 4),
            KeyCap(label: "重做", code: "z", mods: ["primary", "shift"], col: 4, row: 2, colSpan: 4),
            KeyCap(label: "回车", code: "enter", col: 8, row: 2, colSpan: 4),
            KeyCap(label: "左", code: "left", col: 0, row: 3, colSpan: 4),
            KeyCap(label: "下", code: "down", col: 4, row: 3, colSpan: 4),
            KeyCap(label: "右", code: "right", col: 8, row: 3, colSpan: 4),
        ])
    }

    /// 斜杠命令键: 浅珊瑚底 + 等宽 `›_ /xxx`。点一下 = 粘贴该命令文字并提交 Enter (见 ContentView.handle)。
    /// 键面渲染见 KeyTile (sendText 非空且无 icon → 等宽命令样式)。
    private static func cmd(_ command: String, col: Int, row: Int, span: Int) -> KeyCap {
        KeyCap(label: command, col: col, row: row, colSpan: span, tint: .coral, sendText: command)
    }
}
