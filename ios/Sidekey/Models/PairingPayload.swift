import Foundation

/// 扫码/配对码的内容: 电脑地址列表 + 端口 + 令牌。与 server 生成的 JSON 对应。
struct PairingPayload: Codable, Equatable {
    var v: Int = 1
    var hosts: [String]
    var port: Int
    var token: String
    var fp: String?          // 服务端 TLS 证书指纹 (SHA-256 hex); 可选: 旧配对码没有此字段也能解析

    /// 配对码语义错误 (审计 M-2): 仅靠 Codable 解码会把空地址/非法端口/未知版本/坏指纹的「结构正确但语义错误」
    /// 配对码也存成一台「永远连不上」的电脑。这里给出具体且安全(不回显原始内容)的拒绝原因。
    enum ParseError: LocalizedError {
        case notSidekey            // 根本不是 Sidekey 配对码 (解码失败)
        case unsupportedVersion    // 版本比本 App 新, 无法识别
        case noHost                // 没有可用地址
        case badPort               // 端口不在 1...65535
        case badFingerprint        // 指纹不是 64 位十六进制

        var errorDescription: String? {
            switch self {
            case .notSidekey:         return String(localized: "配对码无法识别, 请确认扫的是 Sidekey 电脑端显示的二维码。")
            case .unsupportedVersion: return String(localized: "这个配对码版本比当前 App 新, 请把手机 App 升级到最新版。")
            case .noHost:             return String(localized: "配对码里没有电脑地址, 请在电脑端重新生成二维码。")
            case .badPort:            return String(localized: "配对码里的端口无效, 请在电脑端重新生成二维码。")
            case .badFingerprint:     return String(localized: "配对码里的证书指纹无效, 请在电脑端重新生成二维码。")
            }
        }
    }

    /// 解析并校验配对码。结构正确但语义不合法时抛出带原因的 `ParseError`。
    static func validated(_ raw: String) throws -> PairingPayload {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let data = s.data(using: .utf8),
              let p = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            throw ParseError.notSidekey
        }
        // 只接受本 App 认识的版本; 更高版本可能含必须处理的新字段, 宁可明确拒绝也不静默连错。
        guard p.v <= 1 else { throw ParseError.unsupportedVersion }
        guard p.hosts.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ParseError.noHost
        }
        guard (1...65535).contains(p.port) else { throw ParseError.badPort }
        if let fp = p.fp, !fp.isEmpty {
            let hex = fp.lowercased()
            let isHex64 = hex.count == 64 && hex.allSatisfy { $0.isHexDigit }
            guard isHex64 else { throw ParseError.badFingerprint }
        }
        return p
    }

    /// 把扫到的字符串(JSON)解析成配对信息; 解析或校验不通过返回 nil (宽松 API; 需要具体原因用 `validated`)。
    static func parse(_ raw: String) -> PairingPayload? {
        try? validated(raw)
    }
}
