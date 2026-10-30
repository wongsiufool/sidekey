import Foundation

/// KeyCap 的容错编解码 (§6.4, v1.7):
/// - 读到不认识的 `kind`: 整个键的原始数据 (含嵌套的未知字段) 存进 `rawUnknown`, 保存时原样写回,
///   只用当前的位置 (col/row/span) 覆盖, 让用户在编辑器里挪动占位键仍然有效。
/// - 这样的键 `kind == .unknown`, 界面显示为灰色占位, **不能发出按键**。
/// - 已知类型多出来的未知字段直接忽略, 不报错 (降级后是否保留不作保证)。
extension KeyCap {
    private enum CodingKeys: String, CodingKey {
        case id, label, code, mods, col, row, colSpan, rowSpan, kind, targetLayer, tint, sendText, icon
        case winApp, winTitle, winId, slot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // kind 是必需字段 (和改动前一致); 类型不对也直接报错, 进恢复流程, 不静默默认化。
        let kindString = try c.decode(String.self, forKey: .kind)
        let knownKind = Kind.allCases.first { $0 != .unknown && $0.rawValue == kindString }
        if let knownKind {
            // 已知类型: 必要字段严格解码 (和改动前的合成解码一致), 类型或结构损坏会抛错; 只有旧版本本来就可选的字段允许缺失。
            id = try c.decode(UUID.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            code = try c.decode(String.self, forKey: .code)
            mods = try c.decode([String].self, forKey: .mods)
            col = try c.decode(Int.self, forKey: .col)
            row = try c.decode(Int.self, forKey: .row)
            colSpan = try c.decode(Int.self, forKey: .colSpan)
            rowSpan = try c.decode(Int.self, forKey: .rowSpan)
            kind = knownKind
            rawUnknown = nil
            targetLayer = try c.decodeIfPresent(String.self, forKey: .targetLayer)
            tint = try c.decodeIfPresent(KeyTint.self, forKey: .tint)
            sendText = try c.decodeIfPresent(String.self, forKey: .sendText)
            icon = try c.decodeIfPresent(String.self, forKey: .icon)
            winApp = try c.decodeIfPresent(String.self, forKey: .winApp)
            winTitle = try c.decodeIfPresent(String.self, forKey: .winTitle)
            winId = try c.decodeIfPresent(Int.self, forKey: .winId)
            slot = try c.decodeIfPresent(Int.self, forKey: .slot)
        } else {
            // 未知类型: 整键原始数据原样保留; 这里只取显示占位键用得到的字段, 缺失 / 类型不对就用默认值 (原始数据不受影响)。
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            label = (try? c.decode(String.self, forKey: .label)) ?? "?"
            code = ""
            mods = []
            col = (try? c.decode(Int.self, forKey: .col)) ?? 0
            row = (try? c.decode(Int.self, forKey: .row)) ?? 0
            colSpan = max(1, (try? c.decode(Int.self, forKey: .colSpan)) ?? 1)
            rowSpan = max(1, (try? c.decode(Int.self, forKey: .rowSpan)) ?? 1)
            kind = .unknown
            // 原始数据取自带原文数字的 JSON 树 (SidekeyJSON.decode 提供); 拿不到就报错进恢复流程, 不悄悄丢精度。
            guard let tree = decoder.userInfo[SidekeyJSON.rawTreeKey] as? JSONValue,
                  let node = SidekeyJSON.node(at: decoder.codingPath, in: tree), case .object = node else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "未知类型的键必须经 SidekeyJSON.decode 读取 (保留原始数据)"))
            }
            rawUnknown = UnknownKeyData(tree: node, col: col, row: row, colSpan: colSpan, rowSpan: rowSpan, id: id)
            if label.isEmpty { label = "?" }
        }
    }

    func encode(to encoder: Encoder) throws {
        if kind == .unknown, let u = rawUnknown, case .object(var raw) = u.tree {
            // 位置字段只在真的被挪动 / 缩放过时才改写 (和解码时的快照比); 没动过的键整键保持原文
            func overlay(_ key: String, _ value: Int, _ origin: Int) {
                guard value != origin else { return }
                raw[key] = .number(String(value))
            }
            overlay("col", col, u.col); overlay("row", row, u.row)
            overlay("colSpan", colSpan, u.colSpan); overlay("rowSpan", rowSpan, u.rowSpan)
            if let origin = u.id, origin != id { raw["id"] = .string(id.uuidString) }      // 复制出来的键: id 换新 (原键没变 id 时原文不动)
            let text = JSONValue.object(raw).serialized()
            if let sink = encoder.userInfo[SidekeyJSON.rawSinkKey] as? SidekeyJSON.RawSink {
                var single = encoder.singleValueContainer()
                try single.encode(sink.add(text))          // 占位, 编码完成后由 SidekeyJSON.encode 换成原文
            } else {
                throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                    debugDescription: "含未知类型键的数据必须经 SidekeyJSON.encode 写出 (保留原始数据)"))
            }
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(code, forKey: .code)
        try c.encode(mods, forKey: .mods)
        try c.encode(col, forKey: .col)
        try c.encode(row, forKey: .row)
        try c.encode(colSpan, forKey: .colSpan)
        try c.encode(rowSpan, forKey: .rowSpan)
        // 没有原始数据的 .unknown 键 (理论上不会出现) 退回成普通键写出, 避免写出自己都读不懂的类型。
        try c.encode(kind == .unknown ? Kind.normal : kind, forKey: .kind)
        try c.encodeIfPresent(targetLayer, forKey: .targetLayer)
        try c.encodeIfPresent(tint, forKey: .tint)
        try c.encodeIfPresent(sendText, forKey: .sendText)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(winApp, forKey: .winApp)
        try c.encodeIfPresent(winTitle, forKey: .winTitle)
        try c.encodeIfPresent(winId, forKey: .winId)
        try c.encodeIfPresent(slot, forKey: .slot)
    }
}
