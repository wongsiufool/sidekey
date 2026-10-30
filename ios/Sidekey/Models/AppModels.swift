import Foundation

/// 一个「模式」= 一套完整独立的键盘 (含若干层)。如「Sidekey」「工作」。
/// 模式是架在「层(KeyLayer)」之上的一级: 一个 Mode 内部仍可有 base/more 等层,
/// 靠 FN/「更多」键切层; 而模式本身是从主页选择、各自独立的整套键盘。
struct Mode: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String                  // 显示名, 如「Sidekey」「工作」
    var layers: [KeyLayer]            // 复用现有 KeyLayer / KeyCap
    var kind: ModeKind = .grid        // 稳定的类型标识 (§4.9): 不靠名字认模式, 用户可以自建同名模式

    private enum CodingKeys: String, CodingKey { case id, name, layers, kind }

    /// 新建一个模式: 默认给一套 base + more 层, 直接能用。
    static func makeDefault(name: String) -> Mode {
        Mode(name: name, layers: DefaultLayout.makeDefault())
    }
}

/// 一台「电脑」= 连接信息 + 它自己的一套模式集。多台电脑各自独立保存布局。
struct Computer: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String                  // 显示名, 如「办公台式机」(默认取配对/IP)
    var host: String = ""
    var port: Int = 8765
    var token: String = ""
    var fingerprint: String = ""      // 服务端 TLS 证书指纹 (扫码拿到); 空 = 不 pin、只加密
    var modes: [Mode]
    var lastModeID: UUID? = nil       // 切回这台电脑时, 恢复上次用的模式
    var pinned: Bool? = nil           // 置顶到顶栏快捷切换条; 用可选以兼容老存档(缺 key 解码为 nil = 未置顶)

    /// 是否置顶到顶栏快捷条 (nil/false = 否)。
    var isPinned: Bool { pinned == true }

    /// 新建一台电脑, 默认带两个内置模式: 「Vibe Coding」(默认) + 「vibecoding键盘模式」。
    static func make(name: String, host: String = "", port: Int = 8765,
                     token: String = "", fingerprint: String = "") -> Computer {
        let modes = BuiltinModes.makeAll()        // [Vibe, vibecoding键盘], Vibe 在前
        return Computer(name: name, host: host, port: port, token: token,
                        fingerprint: fingerprint, modes: modes, lastModeID: modes.first?.id)
    }
}

/// 模式类型。grid=可编辑的网格键位 (现有全部模式); laptopKeyboard=内置「笔记本键盘」(M3 起使用, 键位固定, 不进 §6)。
/// 读到本版不认识的标识时记住原字符串 (.unknown), 保存时原样写回, 不让整份存档读取失败 (§6.4)。
enum ModeKind: Hashable, Codable {
    case grid, laptopKeyboard
    case unknown(String)

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        switch s {
        case "grid": self = .grid
        case "laptopKeyboard": self = .laptopKeyboard
        default: self = .unknown(s)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .grid: try c.encode("grid")
        case .laptopKeyboard: try c.encode("laptopKeyboard")
        case .unknown(let s): try c.encode(s)
        }
    }
}

extension Mode {
    /// 老存档没有 kind (按网格模式)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(ModeKind.self, forKey: .kind) ?? .grid     // 旧存档没有 kind: 网格模式
        // 网格模式必须有 layers (缺失 = 结构损坏, 不静默当空); 笔记本键盘等固定键位的模式没有页
        layers = kind == .grid ? try c.decode([KeyLayer].self, forKey: .layers)
                               : (try c.decodeIfPresent([KeyLayer].self, forKey: .layers) ?? [])
    }
}
