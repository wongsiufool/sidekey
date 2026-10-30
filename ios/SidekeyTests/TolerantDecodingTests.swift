import XCTest
@testable import Sidekey

/// §6.4 容错解码与主存档恢复 (T-DATA-1 / T-DATA-3 / T-DATA-4)。
@MainActor
final class TolerantDecodingTests: XCTestCase {

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func object(_ data: Data) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    // 未知 kind: 能读出, 标记为 .unknown, 不当普通键。
    func testUnknownKindDecodesAsUnknown() throws {
        let cap = try SidekeyJSON.decode(KeyCap.self, from: json(#"{"label":"X","code":"a","col":2,"row":1,"colSpan":1,"rowSpan":1,"kind":"futureKind"}"#))
        XCTAssertEqual(cap.kind, .unknown)
        XCTAssertNotNil(cap.rawUnknown)
    }

    // 带嵌套未知字段的未知类型: 来回编解码后原始字段全部保留。
    func testUnknownKindRoundTripKeepsNestedFields() throws {
        let src = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"F","code":"","mods":[],"col":0,"row":0,"colSpan":2,"rowSpan":1,"kind":"futureKind","payload":{"a":[1,2.5,true,null,"s"],"nested":{"k":"v"}},"newField":7}"#
        let cap = try SidekeyJSON.decode(KeyCap.self, from: json(src))
        let out = object(try SidekeyJSON.encode(cap))
        XCTAssertEqual(out["kind"] as? String, "futureKind")
        XCTAssertEqual(out["newField"] as? Int, 7)
        let payload = out["payload"] as! [String: Any]
        XCTAssertEqual((payload["nested"] as! [String: String])["k"], "v")
        XCTAssertEqual((payload["a"] as! [Any]).count, 5)
        XCTAssertEqual(out["id"] as? String, "6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }

    // 占位键被挪动后, 新位置写回, 其余原样。
    func testUnknownKeyMoveIsWritten() throws {
        var cap = try SidekeyJSON.decode(KeyCap.self, from: json(#"{"label":"F","kind":"futureKind","col":0,"row":0,"colSpan":1,"rowSpan":1,"x":1}"#))
        cap.col = 3; cap.row = 2
        let out = object(try SidekeyJSON.encode(cap))
        XCTAssertEqual(out["col"] as? Int, 3)
        XCTAssertEqual(out["row"] as? Int, 2)
        XCTAssertEqual(out["x"] as? Int, 1)
    }

    // 已知类型多一个不认识的字段: 完整读出、不报错。
    func testKnownKindWithExtraFieldDecodes() throws {
        let cap = try SidekeyJSON.decode(KeyCap.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"Esc","code":"esc","mods":[],"kind":"normal","col":0,"row":0,"colSpan":1,"rowSpan":1,"brandNew":"zzz"}"#))
        XCTAssertEqual(cap.kind, .normal)
        XCTAssertEqual(cap.code, "esc")
        XCTAssertNil(cap.rawUnknown)
    }

    // .window / .agentSlot 来回编解码。
    func testWindowAndAgentSlotRoundTrip() throws {
        var w = KeyCap(label: "W", col: 1, row: 0, kind: .window)
        w.winApp = "Paseo"; w.winTitle = "对话"; w.winId = 42
        var a = KeyCap(label: "A", col: 2, row: 0, kind: .agentSlot)
        a.slot = 3
        let layer = KeyLayer(id: "base", columns: 4, keys: [w, a])
        let back = try SidekeyJSON.decode(KeyLayer.self, from: SidekeyJSON.encode(layer))
        XCTAssertEqual(back, layer)
    }

    // 老存档的 Mode 没有 kind / 笔记本键盘没有 layers; 未知模式类型记住原字符串。
    func testModeKind() throws {
        let id = UUID().uuidString
        let old = try SidekeyJSON.decode(Mode.self, from: json(#"{"id":"\#(id)","name":"X","layers":[]}"#))
        XCTAssertEqual(old.kind, .grid)
        let laptop = try SidekeyJSON.decode(Mode.self, from: json(#"{"id":"\#(id)","name":"X","kind":"laptopKeyboard"}"#))
        XCTAssertEqual(laptop.kind, .laptopKeyboard)
        XCTAssertTrue(laptop.layers.isEmpty)
        let future = try SidekeyJSON.decode(Mode.self, from: json(#"{"id":"\#(id)","name":"X","layers":[],"kind":"hologram"}"#))
        XCTAssertEqual(future.kind, .unknown("hologram"))
        XCTAssertEqual(object(try SidekeyJSON.encode(future))["kind"] as? String, "hologram")
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // T-DATA-3 (v5): 主存档写坏 → 不覆盖原始数据, 进入恢复流程; 备份存在; 选择继续后才写新档。
    func testCorruptV5IsNotOverwritten() {
        let d = freshDefaults("tdata3")
        let garbage = Data(#"{"computers": "oops""#.utf8)
        d.set(garbage, forKey: "sidekey.app.v5")
        let store = LayoutStore(defaults: d)
        XCTAssertNotNil(store.recovery)
        XCTAssertEqual(store.recovery?.rawData, garbage)
        XCTAssertEqual(LayoutStore.corruptBackupKeys(in: d).compactMap { d.data(forKey: $0) }, [garbage])
        _ = store.upsertComputer(name: "A", host: "1.2.3.4", port: 1, token: "t")
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), garbage, "恢复期间不得覆盖原始数据")
        store.resolveRecoveryWithFreshData()
        XCTAssertNil(store.recovery)
        XCTAssertNotEqual(d.data(forKey: "sidekey.app.v5"), garbage)
        XCTAssertEqual(LayoutStore.corruptBackupKeys(in: d).compactMap { d.data(forKey: $0) }, [garbage], "备份保留")
    }

    // T-DATA-1 的单元部分: 没有 Mode.kind 的旧存档升级后, 电脑与每个键一个不差。
    func testLegacySaveWithoutModeKindUpgradesIntact() throws {
        let d = freshDefaults("tdata1")
        let a = LayoutStore(defaults: d)
        let id = a.addMode(named: "自定义")!
        a.selectMode(id)
        a.addKey(layerID: "base")
        let before = a.computers
        // 模拟 1.0: 存档里的 mode 没有 kind 字段
        var root = object(d.data(forKey: "sidekey.app.v5")!)
        var cs = root["computers"] as! [[String: Any]]
        for i in cs.indices {
            var ms = cs[i]["modes"] as! [[String: Any]]
            for j in ms.indices { ms[j].removeValue(forKey: "kind") }
            cs[i]["modes"] = ms
        }
        root["computers"] = cs
        d.set(try JSONSerialization.data(withJSONObject: root), forKey: "sidekey.app.v5")
        let b = LayoutStore(defaults: d)
        XCTAssertNil(b.recovery)
        XCTAssertEqual(b.computers.map(\.id), before.map(\.id))
        XCTAssertEqual(b.computers.flatMap(\.modes).map(\.layers), before.flatMap(\.modes).map(\.layers))
        XCTAssertTrue(b.computers.flatMap(\.modes).allSatisfy { $0.kind == .grid })
    }

    // MARK: 审计修复 (Codex M1 阻断 1/2/3, 重要 6/7)

    private let fullKey = #""id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"X","code":"a","mods":[],"col":0,"row":0,"colSpan":1,"rowSpan":1"#

    // 已知类型的损坏键 (code 是数字) 不能被悄悄默认成空字符串: 解码要失败, 由存档层进恢复流程。
    func testKnownKindWithWrongFieldTypeThrows() {
        XCTAssertThrowsError(try SidekeyJSON.decode(KeyCap.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"X","code":42,"mods":["primary"],"col":0,"row":0,"colSpan":1,"rowSpan":1,"kind":"normal"}"#)))
        XCTAssertThrowsError(try SidekeyJSON.decode(KeyCap.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"X","code":"a","mods":[],"col":"0","row":0,"colSpan":1,"rowSpan":1,"kind":"normal"}"#)))
        XCTAssertThrowsError(try SidekeyJSON.decode(KeyCap.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"X","code":"a","mods":[],"col":0,"row":0,"colSpan":1,"rowSpan":1}"#)), "kind 缺失")
        XCTAssertThrowsError(try SidekeyJSON.decode(Mode.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"X"}"#)), "网格模式缺 layers")
    }

    // 合法 JSON、无效结构 (空电脑数组 / 电脑没有模式 / 键损坏): 进恢复流程, 不回退旧档、不改写原档。
    func testStructurallyInvalidV5GoesToRecovery() {
        let cases: [(String, String)] = [
            ("emptyComputers", #"{"computers":[],"currentComputerID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","currentModeID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#),
            ("noModes", #"{"computers":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"C","host":"","port":8765,"token":"","fingerprint":"","modes":[]}],"currentComputerID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","currentModeID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#),
        ]
        for (name, raw) in cases {
            let d = freshDefaults("invalid-\(name)")
            let data = Data(raw.utf8)
            d.set(data, forKey: "sidekey.app.v5")
            // 即使旧版本 v4 存在, 也不能回退
            d.set(Data("legacy".utf8), forKey: "sidekey.app.v4")
            let store = LayoutStore(defaults: d)
            XCTAssertNotNil(store.recovery, name)
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), data, "\(name): 原档不被改写")
            XCTAssertEqual(store.computers.first?.modes.isEmpty, false, "\(name): 恢复态用有效的全新默认数据, 不越界")
        }
    }

    // 只有 v5 不存在时才回退旧版本。
    func testLegacyFallbackOnlyWhenV5Absent() {
        let d = freshDefaults("legacy-only")
        let store = LayoutStore(defaults: d)          // 全新: 种默认
        XCTAssertNil(store.recovery)
    }

    // 未知键里的大整数、高精度小数: 来回编解码后文本数值不变。
    func testUnknownKeyKeepsBigNumbersExactly() throws {
        let long = "0.12345678901234567890123456789012345678901234567890123456789"
        let bigInt = "123456789012345678901234567890123456789012345678901234567890"
        let src = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"F","kind":"futureKind","col":0,"row":0,"colSpan":1,"rowSpan":1,"payload":{"id":18446744073709551615,"neg":-9223372036854775808,"pi":3.14159265358979323846264338,"e":1.5e300,"long":\#(long),"big":\#(bigInt),"exp":1E-7}}"#
        let cap = try SidekeyJSON.decode(KeyCap.self, from: json(src))
        let out = String(decoding: try SidekeyJSON.encode(cap), as: UTF8.self)
        XCTAssertTrue(out.contains("18446744073709551615"), out)
        XCTAssertTrue(out.contains("-9223372036854775808"), out)
        XCTAssertTrue(out.contains("3.14159265358979323846264338"), out)
        XCTAssertTrue(out.contains(long), "超过 Decimal 精度的长小数也要原样: \(out)")
        XCTAssertTrue(out.contains(bigInt), "超长整数不能被截成零: \(out)")
        XCTAssertTrue(out.contains("1E-7") || out.contains("1e-7"), out)
    }

    // 没挪动的未知键: 整键保持原样 (不重写位置字段), 缺省位置字段也不凭空补出来。
    func testUnmovedUnknownKeyIsNotRewritten() throws {
        let src = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"F","kind":"futureKind","extra":{"a":1}}"#
        let cap = try SidekeyJSON.decode(KeyCap.self, from: json(src))
        let out = object(try SidekeyJSON.encode(cap))
        XCTAssertNil(out["col"]); XCTAssertNil(out["row"]); XCTAssertNil(out["colSpan"]); XCTAssertNil(out["rowSpan"])
        XCTAssertEqual((out["extra"] as? [String: Int])?["a"], 1)
    }

    // 连续两次损坏: 每次的原档都有备份, 第二次不会盖掉第一次。
    func testSecondCorruptionKeepsBothBackups() {
        let d = freshDefaults("two-corrupt")
        let a = Data("{ bad A".utf8), b = Data("{ bad B".utf8)
        d.set(a, forKey: "sidekey.app.v5")
        let s1 = LayoutStore(defaults: d)
        s1.resolveRecoveryWithFreshData()
        d.set(b, forKey: "sidekey.app.v5")
        let s2 = LayoutStore(defaults: d)
        XCTAssertEqual(s2.recovery?.rawData, b)
        s2.resolveRecoveryWithFreshData()
        let backups = LayoutStore.corruptBackupKeys(in: d).compactMap { d.data(forKey: $0) }
        XCTAssertEqual(Set(backups), [a, b])
    }

    // 按电脑存档损坏: 先备份, 不重新迁移旧全局值。
    func testPerComputerCorruptIsBackedUpAndNotRemigrated() {
        let d = freshDefaults("pc-corrupt")
        d.set(PermissionMode.plan.rawValue, forKey: PerComputerStore.legacyPermissionKey)
        let bad = Data("{ nope".utf8)
        d.set(bad, forKey: PerComputerStore.storeKey)
        let id = UUID()
        let s = PerComputerStore(defaults: d, computerIDs: [id])
        XCTAssertEqual(s.permissionRaw(for: id), PermissionMode.ask.rawValue, "不再从旧全局值迁移")
        XCTAssertEqual(LayoutStore.corruptBackupKeys(in: d, prefix: PerComputerStore.storeKey + ".corrupt").compactMap { d.data(forKey: $0) }, [bad])
    }

    // 审计第二轮: 位置字段只在真的被编辑过才改写; 没动过的键整键保持原样, 即使位置字段不是合法整数。
    func testUnparsablePositionIsKeptUntilReallyMoved() throws {
        let src = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"F","kind":"futureKind","col":"weird","row":1.5,"colSpan":1,"rowSpan":1}"#
        var cap = try SidekeyJSON.decode(KeyCap.self, from: json(src))
        let untouched = object(try SidekeyJSON.encode(cap))
        XCTAssertEqual(untouched["col"] as? String, "weird", "没动过: 位置字段保持原样")
        XCTAssertEqual(untouched["row"] as? Double, 1.5)
        cap.row = 4                                      // 真的挪动了 row
        let moved = object(try SidekeyJSON.encode(cap))
        XCTAssertEqual(moved["row"] as? Int, 4)
        XCTAssertEqual(moved["col"] as? String, "weird", "没动的字段仍保持原样")
    }

    // 解析器: 转义、Unicode、代理对、嵌套、非法输入。
    func testJSONParserRoundTripsEscapesAndRejectsGarbage() throws {
        let src = #"{"a":"line\nbreak \"q\" \u00e9 \ud83d\ude00","b":[1,2.50,-0,true,null,{"c":[]}]}"#
        let tree = try JSONParser.parse(Data(src.utf8))
        let again = try JSONParser.parse(Data(tree.serialized().utf8))
        XCTAssertEqual(tree, again)
        guard case .object(let o) = tree, case .string(let a)? = o["a"] else { return XCTFail() }
        XCTAssertEqual(a, "line\nbreak \"q\" é 😀")
        XCTAssertTrue(tree.serialized().contains("2.50"), "数字原文保留 (尾随 0 不丢)")
        for bad in ["{", "[1,]", #"{"a":}"#, "01", "1.", "nul", #"{"a":1} x"#, #""\x""#] {
            XCTAssertThrowsError(try JSONParser.parse(Data(bad.utf8)), bad)
        }
    }

    // 不经 SidekeyJSON 读未知键: 报错 (进恢复流程), 不悄悄丢精度。
    func testPlainDecoderRejectsUnknownKeyInsteadOfLosingData() {
        XCTAssertThrowsError(try JSONDecoder().decode(KeyCap.self, from: json(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","label":"F","kind":"futureKind"}"#)))
    }

    // 整份存档里的未知键: 经 LayoutStore 读写后, 其余数据都在, 未知键原文 (含长数字) 保留。
    func testUnknownKeyInsideFullSaveSurvivesLoadAndSave() throws {
        let d = freshDefaults("unknown-in-save")
        let a = LayoutStore(defaults: d)
        let c = a.currentComputer!
        let modeID = a.currentModeID
        _ = c
        var cap = KeyCap(label: "future", col: 0, row: 0, kind: .normal)
        cap.kind = .unknown
        let long = "123456789012345678901234567890123456789012345678901234567890"
        let tree = try JSONParser.parse(Data(#"{"id":"\#(cap.id.uuidString)","label":"future","kind":"futureKind","n":\#(long)}"#.utf8))
        cap.rawUnknown = UnknownKeyData(tree: tree, col: 0, row: 0, colSpan: 1, rowSpan: 1)
        a.addKeyForTesting(cap, mode: modeID)
        let raw = d.data(forKey: "sidekey.app.v5")!
        XCTAssertTrue(String(decoding: raw, as: UTF8.self).contains(long), "写出的存档里长数字原文保留")
        let b = LayoutStore(defaults: d)
        XCTAssertNil(b.recovery)
        let back = b.computers.flatMap(\.modes).flatMap(\.layers).flatMap(\.keys).first { $0.id == cap.id }
        XCTAssertEqual(back?.kind, .unknown)
        XCTAssertEqual(back?.rawUnknown?.tree, tree)
    }

    // MARK: 审计第三轮: 重复键 / 非法 UTF-8 / 解析失败不绕过恢复 / 上限
    private func fullSave(withKey keyJSON: String) -> Data {
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        return Data(#"{"computers":[{"id":"\#(id)","name":"C","host":"","port":8765,"token":"","fingerprint":"","modes":[{"id":"\#(id)","name":"M","layers":[{"id":"base","columns":4,"keys":[\#(keyJSON)]}]}],"lastModeID":"\#(id)"}],"currentComputerID":"\#(id)","currentModeID":"\#(id)","builtinVersion":11}"#.utf8)
    }

    func testParserRejectsDuplicateKeysIncludingNested() {
        for bad in [#"{"a":1,"a":2}"#, #"{"x":{"y":1,"y":2}}"#, #"[{"k":1,"k":1}]"#] {
            XCTAssertThrowsError(try JSONParser.parse(Data(bad.utf8)), bad)
        }
    }

    func testParserRejectsInvalidUTF8() {
        var bytes = Array(#"{"a":"x"#.utf8); bytes.append(0xFF); bytes.append(contentsOf: Array(#"y"}"#.utf8))
        XCTAssertThrowsError(try JSONParser.parse(Data(bytes)))
        XCTAssertThrowsError(try JSONParser.parse(Data(#"{"a":"\ud800"}"#.utf8)), "孤立的代理项转义也非法")
    }

    func testParserLimits() {
        XCTAssertThrowsError(try JSONParser.parse(Data(repeating: 0x20, count: JSONParser.maxBytes + 1)), "过大")
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        XCTAssertThrowsError(try JSONParser.parse(Data(deep.utf8)), "超深嵌套")
    }

    // 重复 kind 会让 JSONDecoder (取第一个) 与自写解析器 (取最后一个) 对不上: 整份存档必须读失败。
    func testDuplicateKindInFullSaveIsRejectedNotRewritten() throws {
        let key = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"future","kind":"normal","label":"X","payload":{"x":1}}"#
        XCTAssertThrowsError(try SidekeyJSON.decode(LayoutStore.Persisted.self, from: fullSave(withKey: key)))
        let d = freshDefaults("dup-kind")
        let raw = fullSave(withKey: key)
        d.set(raw, forKey: "sidekey.app.v5")
        let store = LayoutStore(defaults: d)
        XCTAssertNotNil(store.recovery, "首次启动就进恢复页, 不是第二次")
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), raw, "原档没被改写")
    }

    func testInvalidUTF8InUnknownKeyIsRejectedAndNotRewritten() {
        let good = fullSave(withKey: #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"future","label":"AB"}"#)
        var broken = [UInt8](good)
        let needle = Array(#""label":"AB""#.utf8)
        let at = (0...(broken.count - needle.count)).first { Array(broken[$0..<($0 + needle.count)]) == needle }!
        broken[at + needle.count - 1] = 0xFF                                           // 把未知键 label 里的 "B" 换成非法字节
        let d = freshDefaults("bad-utf8")
        d.set(Data(broken), forKey: "sidekey.app.v5")
        let store = LayoutStore(defaults: d)
        XCTAssertNotNil(store.recovery)
        XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), Data(broken), "原档没被改写")
    }

    // 解析器失败不能绕过: 即使 JSONDecoder 能读, 也必须先过自写解析器 (这里用 JSONDecoder 能接受的非法 JSON 前缀垃圾验证)。
    func testSidekeyDecodeRequiresParserSuccess() {
        let good = fullSave(withKey: #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"normal","label":"X","code":"a","mods":[],"col":0,"row":0,"colSpan":1,"rowSpan":1}"#)
        XCTAssertNoThrow(try SidekeyJSON.decode(LayoutStore.Persisted.self, from: good))
        var bad = good; bad.append(contentsOf: Data(" garbage".utf8))
        XCTAssertThrowsError(try SidekeyJSON.decode(LayoutStore.Persisted.self, from: bad))
    }
}
