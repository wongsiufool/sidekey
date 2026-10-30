import Foundation

/// 任意 JSON 值, **数字保留原文 token** (不转 Double / Decimal, 长整数、长小数都不会失真)。
/// 容错解码用: 读到不认识的按键类型时, 整个键的原始数据存下来, 保存时原样写回 (§6.4)。
/// 通过 `JSONParser` 解析、`serialized()` 输出, 不经过 JSONDecoder / JSONEncoder 的数值通道。
indirect enum JSONValue: Hashable {
    case null
    case bool(Bool)
    case number(String)               // 数字的原文, 如 "18446744073709551615"、"0.1234567890123456789012345"、"1e-7"
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int? { if case .number(let t) = self { return Int(t) }; return nil }
}

// MARK: - 序列化 (数字原样输出; 对象键按字典序, 输出稳定)
extension JSONValue {
    func serialized() -> String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let t): return t
        case .string(let s): return Self.quote(s)
        case .array(let a): return "[" + a.map { $0.serialized() }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { Self.quote($0) + ":" + o[$0]!.serialized() }.joined(separator: ",") + "}"
        }
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}

// MARK: - 解析器 (RFC 8259, 数字只校验语法、保留原文)
struct JSONParser {
    struct ParseError: Error { var offset: Int; var reason: String = "" }

    private let b: [UInt8]
    private var i = 0
    private var nodes = 0
    private static let maxDepth = 512
    /// 存档大小 / 节点总数上限: 超过就拒绝 (进恢复流程, 原档保留), 不让畸形存档拖垮启动。
    nonisolated(unsafe) static var maxBytes = 16 * 1024 * 1024      // 可变仅为测试 (用小上限走完整流程), 生产不改
    nonisolated(unsafe) static var maxNodes = 2_000_000

    static func parse(_ data: Data, maxBytes: Int = JSONParser.maxBytes, maxNodes: Int = JSONParser.maxNodes) throws -> JSONValue {
        guard data.count <= maxBytes else { throw ParseError(offset: 0, reason: "存档过大") }
        // 严格 UTF-8: 非法字节序列不能被「修复」成 U+FFFD 后照样接受 (保存时会悄悄改写原文)
        guard String(data: data, encoding: .utf8) != nil else { throw ParseError(offset: 0, reason: "非法 UTF-8") }
        var p = JSONParser(b: [UInt8](data), maxNodes: maxNodes)
        p.skipWS()
        let v = try p.value(depth: 0)
        p.skipWS()
        guard p.i == p.b.count else { throw ParseError(offset: p.i) }
        return v
    }

    private let nodeLimit: Int
    private init(b: [UInt8], maxNodes: Int) { self.b = b; self.nodeLimit = maxNodes }

    private mutating func skipWS() { while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 } }
    private func peek() -> UInt8? { i < b.count ? b[i] : nil }

    private mutating func value(depth: Int) throws -> JSONValue {
        nodes += 1
        guard nodes <= nodeLimit else { throw ParseError(offset: i, reason: "节点过多") }
        guard depth < Self.maxDepth, let c = peek() else { throw ParseError(offset: i, reason: "嵌套过深或意外结束") }
        switch c {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    private mutating func literal(_ s: String) throws {
        for ch in s.utf8 { guard peek() == ch else { throw ParseError(offset: i) }; i += 1 }
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        i += 1; skipWS()
        var o: [String: JSONValue] = [:]
        if peek() == UInt8(ascii: "}") { i += 1; return .object(o) }
        while true {
            skipWS()
            guard peek() == UInt8(ascii: "\"") else { throw ParseError(offset: i) }
            let k = try string()
            skipWS()
            guard peek() == UInt8(ascii: ":") else { throw ParseError(offset: i) }
            i += 1; skipWS()
            // 重复键: JSONDecoder 和本解析器对「取哪个」可能不一致, 会让原始树与模型解码对不上, 直接拒绝
            guard o[k] == nil else { throw ParseError(offset: i, reason: "重复键 \(k)") }
            o[k] = try value(depth: depth + 1)
            skipWS()
            if peek() == UInt8(ascii: ",") { i += 1; continue }
            if peek() == UInt8(ascii: "}") { i += 1; return .object(o) }
            throw ParseError(offset: i)
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        i += 1; skipWS()
        var a: [JSONValue] = []
        if peek() == UInt8(ascii: "]") { i += 1; return .array(a) }
        while true {
            skipWS()
            a.append(try value(depth: depth + 1))
            skipWS()
            if peek() == UInt8(ascii: ",") { i += 1; continue }
            if peek() == UInt8(ascii: "]") { i += 1; return .array(a) }
            throw ParseError(offset: i)
        }
    }

    private mutating func number() throws -> JSONValue {
        let start = i
        if peek() == UInt8(ascii: "-") { i += 1 }
        func digits(_ p: inout JSONParser) -> Int { var n = 0; while let c = p.peek(), c >= 0x30, c <= 0x39 { p.i += 1; n += 1 }; return n }
        guard let first = peek(), first >= 0x30, first <= 0x39 else { throw ParseError(offset: i) }
        if first == 0x30 { i += 1 } else { _ = digits(&self) }
        if peek() == UInt8(ascii: ".") { i += 1; guard digits(&self) > 0 else { throw ParseError(offset: i) } }
        if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            i += 1
            if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { i += 1 }
            guard digits(&self) > 0 else { throw ParseError(offset: i) }
        }
        return .number(String(decoding: b[start..<i], as: UTF8.self))
    }

    private mutating func string() throws -> String {
        i += 1
        var out = [UInt8]()
        while true {
            guard let c = peek() else { throw ParseError(offset: i) }
            i += 1
            switch c {
            case UInt8(ascii: "\""): return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let e = peek() else { throw ParseError(offset: i) }
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800...0xDBFF).contains(code), peek() == UInt8(ascii: "\\"), i + 1 < b.count, b[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw ParseError(offset: i) }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw ParseError(offset: i) }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw ParseError(offset: i)
                }
            default:
                guard c >= 0x20 else { throw ParseError(offset: i) }
                out.append(c)
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw ParseError(offset: i) }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]; i += 1
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw ParseError(offset: i)
            }
            v = v << 4 | d
        }
        return v
    }
}

// MARK: - 存档编解码入口 (保真)
/// 存档的读写必须走这里: 解码时带上整棵原始 JSON 树 (数字保留原文), 编码时把未知键按原文写回。
/// 直接用普通 JSONDecoder 读到「未知类型的键」会抛错 (进恢复流程), 而不是悄悄丢精度。
enum SidekeyJSON {
    static let rawTreeKey = CodingUserInfoKey(rawValue: "sidekey.rawTree")!
    static let rawSinkKey = CodingUserInfoKey(rawValue: "sidekey.rawSink")!

    /// 编码时收集「要原样写入的 JSON 文本」, 先写占位字符串, 编码完成后整体替换。
    final class RawSink {
        private(set) var table: [String: String] = [:]
        func add(_ text: String) -> String {
            let placeholder = "@@SK-RAW-\(UUID().uuidString)@@"
            table[placeholder] = text
            return placeholder
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // 自写解析器必须先成功 (严格 UTF-8、无重复键、大小 / 深度 / 节点数在上限内), 才继续做模型解码;
        // 否则两套解析可能对同一份数据有不同理解, 读成功后保存就悄悄改了存档。
        let tree = try JSONParser.parse(data)
        let d = JSONDecoder()
        d.userInfo[rawTreeKey] = tree
        return try d.decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        let sink = RawSink()
        e.userInfo[rawSinkKey] = sink
        var data = try e.encode(value)
        guard !sink.table.isEmpty, var s = String(data: data, encoding: .utf8) else { return data }
        for (placeholder, text) in sink.table { s = s.replacingOccurrences(of: "\"\(placeholder)\"", with: text) }
        data = Data(s.utf8)
        return data
    }

    /// 按解码路径在原始 JSON 树里取出对应节点。
    static func node(at path: [CodingKey], in root: JSONValue) -> JSONValue? {
        var cur = root
        for k in path {
            if let idx = k.intValue {
                guard case .array(let a) = cur, a.indices.contains(idx) else { return nil }
                cur = a[idx]
            } else {
                guard case .object(let o) = cur, let n = o[k.stringValue] else { return nil }
                cur = n
            }
        }
        return cur
    }
}
