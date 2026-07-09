import Foundation

/// 一个「模式」= 一套完整独立的键盘 (含若干层)。如「Sidekey」「工作」。
/// 模式是架在「层(KeyLayer)」之上的一级: 一个 Mode 内部仍可有 base/more 等层,
/// 靠 FN/「更多」键切层; 而模式本身是从主页选择、各自独立的整套键盘。
struct Mode: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String                  // 显示名, 如「Sidekey」「工作」
    var layers: [KeyLayer]            // 复用现有 KeyLayer / KeyCap

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
