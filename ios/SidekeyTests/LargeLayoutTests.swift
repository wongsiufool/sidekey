import XCTest
@testable import Sidekey

/// M2 大屏键位: 生成规则 (§6.1, T-GEN-1) 和存储 / 迁移 / 编辑范围 (§6.3、§6.4, T-DATA 的 M2 部分)。
@MainActor
final class LargeLayoutGeneratorTests: XCTestCase {
    private let seed = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func k(_ label: String, _ col: Int, _ row: Int, cs: Int = 1, rs: Int = 1, kind: KeyCap.Kind = .normal, code: String? = nil) -> KeyCap {
        KeyCap(label: label, code: code ?? label.lowercased(), col: col, row: row, colSpan: cs, rowSpan: rs, kind: kind)
    }
    private func rows(_ l: KeyLayer) -> [String: Int] { Dictionary(uniqueKeysWithValues: l.keys.map { ($0.label, $0.row) }) }

    // §6.1 第 10 条: 出厂 Vibe → 专门的 12 列 × 5 行、18 个键
    func testFactoryVibeGetsDedicatedLargeLayout() {
        let src = BuiltinModes.vibe()
        let g = LargeLayoutGenerator.generate(from: src)!
        XCTAssertEqual(g.layers.count, 1)
        let base = g.layers[0]
        XCTAssertEqual(base.id, "base"); XCTAssertEqual(base.columns, 12); XCTAssertEqual(base.keys.count, 18); XCTAssertEqual(base.rowCount, 5)
        func row(_ r: Int) -> [String] { base.keys.filter { $0.row == r }.sorted { $0.col < $1.col }.map(\.label) }
        XCTAssertEqual(row(0), ["⌘C", "⌘V", "⌘A", "⌘Z"])
        XCTAssertEqual(row(1), ["/clear", "/compact", "/usage", "/btw"])
        XCTAssertEqual(row(2), ["权限", "Effort", "↑", "↓"])
        XCTAssertEqual(row(3), ["Tab", "SPACE", "Backspace"])
        XCTAssertEqual(row(4), ["Typeless", "ENTER", "ESC"])
        XCTAssertTrue(base.keys.filter { $0.row <= 2 }.allSatisfy { $0.colSpan == 3 })
        XCTAssertTrue(base.keys.filter { $0.row >= 3 }.allSatisfy { $0.colSpan == 4 })
        XCTAssertTrue(base.keys.filter { $0.row == 0 }.allSatisfy { $0.mods == ["primary"] })
        XCTAssertTrue(base.keys.filter { $0.row == 1 }.allSatisfy { $0.sendText == $0.label && $0.tint == .coral }, "斜杠命令, 样式同 vibecoding键盘模式")
        XCTAssertEqual(base.keys.first { $0.label == "权限" }?.kind, .permission)
        XCTAssertEqual(base.keys.first { $0.label == "Effort" }?.kind, .effort)
        XCTAssertEqual(base.keys.first { $0.label == "Tab" }?.col, 0, "Tab 占原来左键的位置")
        // 沿用原键位 id 的 5 个键
        for label in ["SPACE", "Backspace", "Typeless", "ENTER", "ESC"] {
            XCTAssertEqual(base.keys.first { $0.label == label }?.id, src.layers[0].keys.first { $0.label == label }?.id, label)
        }
        XCTAssertEqual(Set(base.keys.map(\.id)).count, 18, "id 不重复")
        // 鼠标键照第 5 条
        XCTAssertEqual(g.mouseButtons.map(\.code), ["left", "right"])
        XCTAssertEqual(g.mouseButtons[0].id, src.layers[0].keys.first { $0.kind == .mouseButton }?.id)
        XCTAssertTrue(LayoutStore.isStructurallyValid(g))
    }

    // 新加 13 个键的 id 由模式 id 确定性派生: 同一模式两次生成完全相同; 换个模式 id, 新键 id 跟着变, 沿用的 5 个不变
    func testFactoryVibeIDsAreStable() {
        let src = BuiltinModes.vibe()
        XCTAssertEqual(LargeLayoutGenerator.generate(from: src), LargeLayoutGenerator.generate(from: src))
        var other = src; other.id = UUID()
        let a = LargeLayoutGenerator.generate(from: src)!.layers[0].keys, b = LargeLayoutGenerator.generate(from: other)!.layers[0].keys
        let kept: Set<String> = ["SPACE", "Backspace", "Typeless", "ENTER", "ESC"]
        for (x, y) in zip(a, b) where x.label == y.label {
            if kept.contains(x.label) { XCTAssertEqual(x.id, y.id) } else { XCTAssertNotEqual(x.id, y.id, x.label) }
        }
    }

    // 只要改过 Vibe 原键位里的一个键 (哪怕只改标签), 就照第 1–8 条推导, 不补键; 只换 id / 打乱顺序仍算出厂
    func testEditedVibeFallsBackToDerivation() {
        var edited = BuiltinModes.vibe()
        let i = edited.layers[0].keys.firstIndex { $0.label == "ESC" }!
        edited.layers[0].keys[i].label = "Esc!"
        XCTAssertNil(LargeLayoutGenerator.factoryVibe(layers: edited.layers, seed: edited.id))
        XCTAssertEqual(LargeLayoutGenerator.generate(from: edited)!.layers[0].keys.count, 5)
        var reshuffled = BuiltinModes.vibe()
        reshuffled.layers[0].keys.reverse()
        for j in reshuffled.layers[0].keys.indices { reshuffled.layers[0].keys[j].id = UUID() }
        XCTAssertEqual(LargeLayoutGenerator.generate(from: reshuffled)!.layers[0].keys.count, 18)
        // 另外两个内置模式照第 1–8 条 (不补键)
        XCTAssertNil(LargeLayoutGenerator.factoryVibe(layers: BuiltinModes.vibecodingKbd().layers, seed: seed))
        XCTAssertNil(LargeLayoutGenerator.factoryVibe(layers: BuiltinModes.codexMicro().layers, seed: seed))
    }

    // §6.1 第 4 条的例子: 默认 Vibe Coding 的 base 页 (按第 1–8 条推导; 出厂 Vibe 实际走第 10 条, 见下面的用例)
    func testDefaultVibeCodingBase() {
        let src = BuiltinModes.vibe()
        let g = LargeLayoutGenerator.generate(layers: src.layers, seed: src.id)
        XCTAssertEqual(g.layers.count, 1)
        let base = g.layers[0]
        XCTAssertEqual(base.id, "base"); XCTAssertEqual(base.columns, 12)
        XCTAssertEqual(base.keys.map(\.label), ["SPACE", "Backspace", "Typeless", "ENTER", "ESC"], "触控板、左键移出; 其余顺序不变")
        XCTAssertEqual(rows(base), ["SPACE": 0, "Backspace": 0, "Typeless": 1, "ENTER": 1, "ESC": 1], "第 0–4 行被压掉, 结果 2 行")
        XCTAssertEqual(base.keys.first { $0.label == "SPACE" }?.col, 4, "保持原来的 col, 左边空出原先左键的位置")
        XCTAssertEqual(base.rowCount, 2)
        // 鼠标键: 左键取原来的那个 (id / 标签都保留), 右键按默认补上; 顺序左、右
        let left = src.layers[0].keys.first { $0.kind == .mouseButton }!
        XCTAssertEqual(g.mouseButtons.map(\.label), ["左键", "右键"])
        XCTAssertEqual(g.mouseButtons[0].id, left.id)
        XCTAssertEqual(g.mouseButtons.map(\.code), ["left", "right"])
        XCTAssertTrue(g.mouseButtons.allSatisfy { $0.kind == .mouseButton })
        XCTAssertFalse(g.edited)
    }

    // 其余属性原样复制 (id / col / colSpan / rowSpan / tint / icon / mods / sendText ...), 只有 row 重新编号
    func testKeptKeysCopyEveryPropertyExceptRow() {
        let src = BuiltinModes.vibe()
        let g = LargeLayoutGenerator.generate(layers: src.layers, seed: src.id)
        for out in g.layers[0].keys {
            var orig = src.layers[0].keys.first { $0.id == out.id }!
            orig.row = out.row
            XCTAssertEqual(out, orig, out.label)
        }
    }

    // 页里没有触控板、但有鼠标键: 鼠标键照样移出; 只压它腾出来的那一行
    func testMouseButtonsRemovedWithoutTrackpad() {
        let layer = KeyLayer(id: "p", columns: 4, keys: [
            k("A", 0, 0), k("右", 0, 1, cs: 2, kind: .mouseButton, code: "right"), k("B", 0, 2),
        ])
        let g = LargeLayoutGenerator.generate(layers: [layer], seed: seed)
        XCTAssertEqual(g.layers[0].keys.map(\.label), ["A", "B"])
        XCTAssertEqual(rows(g.layers[0]), ["A": 0, "B": 1])
        XCTAssertEqual(g.mouseButtons.map(\.label), ["左键", "右"], "右键取原来的标签; 左键补默认")
    }

    // 整页只有触控板 / 鼠标键: 生成空页并保留 (id / columns 不变)
    func testTrackpadOnlyPageBecomesEmptyPage() {
        let layer = KeyLayer(id: "pad", columns: 6, keys: [k("触控板", 0, 0, cs: 6, rs: 4, kind: .trackpad), k("左", 0, 4, kind: .mouseButton, code: "left")])
        let g = LargeLayoutGenerator.generate(layers: [KeyLayer(id: "base", columns: 2, keys: [k("X", 0, 0)]), layer], seed: seed)
        XCTAssertEqual(g.layers.map(\.id), ["base", "pad"])
        XCTAssertEqual(g.layers[1].keys, [])
        XCTAssertEqual(g.layers[1].columns, 6)
    }

    // 空页原样保留
    func testEmptyPageKept() {
        let g = LargeLayoutGenerator.generate(layers: [KeyLayer(id: "e", columns: 3, keys: [])], seed: seed)
        XCTAssertEqual(g.layers, [KeyLayer(id: "e", columns: 3, keys: [])])
    }

    // 原本就空的行保留 (用户留的空白), 只压移除后新出现的空行
    func testOriginallyEmptyRowsKept() {
        // 第 1 行原本就空; 第 3 行原本是触控板 → 被压掉
        let layer = KeyLayer(id: "p", columns: 4, keys: [
            k("A", 0, 0), k("B", 0, 2), k("触控板", 0, 3, cs: 4, kind: .trackpad), k("C", 0, 4),
        ])
        let g = LargeLayoutGenerator.generate(layers: [layer], seed: seed)
        XCTAssertEqual(rows(g.layers[0]), ["A": 0, "B": 2, "C": 3], "第 1 行的空白保留; 第 3 行压掉")
    }

    // 跨行键覆盖的行算「被覆盖」: 触控板和一个跨行键并排时, 被跨行键覆盖的行不压
    func testRowSpanKeepsRowsCovered() {
        let layer = KeyLayer(id: "p", columns: 6, keys: [
            k("触控板", 0, 0, cs: 4, rs: 3, kind: .trackpad),
            k("TALL", 4, 1, rs: 3),           // 覆盖 1–3 行
            k("Z", 0, 4),
        ])
        let g = LargeLayoutGenerator.generate(layers: [layer], seed: seed)
        // 第 0 行只被触控板覆盖 → 压掉; 1、2 行还有 TALL → 保留
        XCTAssertEqual(rows(g.layers[0]), ["TALL": 0, "Z": 3])
        XCTAssertEqual(g.layers[0].keys.first { $0.label == "TALL" }?.rowSpan, 3)
    }

    // 多页里分别有左键、右键 (含重复): 按左 / 右去重, 标签取第一次出现的; 顺序固定左、右
    func testMouseButtonsDedupedAcrossPages() {
        let p1 = KeyLayer(id: "a", columns: 4, keys: [k("右一", 0, 0, kind: .mouseButton, code: "right"), k("X", 1, 0)])
        let p2 = KeyLayer(id: "b", columns: 4, keys: [k("左一", 0, 0, kind: .mouseButton, code: "left"), k("右二", 1, 0, kind: .mouseButton, code: "right")])
        let p3 = KeyLayer(id: "c", columns: 4, keys: [k("左二", 0, 0, kind: .mouseButton, code: "LEFT")])
        let g = LargeLayoutGenerator.generate(layers: [p1, p2, p3], seed: seed)
        XCTAssertEqual(g.mouseButtons.map(\.label), ["左一", "右一"])
        XCTAssertEqual(g.layers.map { $0.keys.map(\.label) }, [["X"], [], []])
    }

    // 功能键的引用和属性不断: .layer / targetLayer、.record、.permission、.effort、.window、.agentSlot、未知类型
    func testFunctionKeysAndReferencesPreserved() throws {
        var jump = k("→B", 0, 0, kind: .layer); jump.targetLayer = "b"
        var win = k("Win", 1, 0, kind: .window); win.winApp = "Paseo"; win.winTitle = "T"; win.winId = 42
        var slot = k("S", 2, 0, kind: .agentSlot); slot.slot = 3
        let unknownJSON = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"futureKind","label":"F","col":3,"row":0,"nested":{"a":[1,2.50,{"b":null}]}}"#
        let unknown = try SidekeyJSON.decode(KeyCap.self, from: Data(unknownJSON.utf8))
        let a = KeyLayer(id: "a", columns: 4, keys: [jump, win, slot, unknown,
                                                    k("R", 0, 1, kind: .record), k("P", 1, 1, kind: .permission), k("E", 2, 1, kind: .effort)])
        let b = KeyLayer(id: "b", columns: 4, keys: [k("触控板", 0, 0, cs: 4, kind: .trackpad)])
        let g = LargeLayoutGenerator.generate(layers: [a, b], seed: seed)
        XCTAssertEqual(g.layers[0].keys, a.keys, "没有被移除的行, 所有键原样")
        XCTAssertEqual(g.layers.map(\.id), ["a", "b"], "目标页 b 变成空页但仍在, 跳转键的引用不断")
        XCTAssertEqual(g.layers[0].keys[0].targetLayer, "b")
        // 未知类型的键: 来回编码后原始数据 (含嵌套字段) 不变
        let back = try SidekeyJSON.decode(LargeLayout.self, from: try SidekeyJSON.encode(g))
        XCTAssertEqual(back, g)
        XCTAssertEqual(back.layers[0].keys[3].rawUnknown, unknown.rawUnknown)
    }

    // 确定性: 同样输入 → 同样结果 (含补上的鼠标键 id); 不同模式 (种子) 补的 id 不同
    func testDeterministic() {
        let layers = BuiltinModes.vibe().layers
        let a = LargeLayoutGenerator.generate(layers: layers, seed: seed)
        for _ in 0..<5 { XCTAssertEqual(LargeLayoutGenerator.generate(layers: layers, seed: seed), a) }
        let other = LargeLayoutGenerator.generate(layers: layers, seed: UUID())
        XCTAssertNotEqual(other.mouseButtons[1].id, a.mouseButtons[1].id)
        XCTAssertEqual(other.layers, a.layers)
    }

    // 笔记本键盘模式 (§4.9) 和不认识的模式类型不生成
    func testNonGridModesNotGenerated() {
        var laptop = Mode.makeDefault(name: "L"); laptop.kind = .laptopKeyboard
        var future = Mode.makeDefault(name: "F"); future.kind = .unknown("futureMode")
        XCTAssertNil(LargeLayoutGenerator.generate(from: laptop))
        XCTAssertNil(LargeLayoutGenerator.generate(from: future))
    }

    // 所有内置模式都能生成, 生成结果结构合法 (存档读取用的同一套检查)
    func testBuiltinsGenerateValidLayouts() {
        for m in BuiltinModes.makeAll() + [BuiltinModes.mouse()] where m.kind == .grid {     // 笔记本键盘不生成大屏键位 (§4.9)
            let g = LargeLayoutGenerator.generate(from: m)!
            XCTAssertTrue(LayoutStore.isStructurallyValid(g), m.name)
            XCTAssertFalse(g.layers.flatMap(\.keys).contains { $0.kind == .trackpad || $0.kind == .mouseButton }, m.name)
        }
    }
}

@MainActor
final class LargeLayoutStoreTests: XCTestCase {
    private func defaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!; d.removePersistentDomain(forName: name); return d
    }
    private func withLimit(_ limit: Int, _ body: () -> Void) {
        let old = JSONParser.maxBytes; defer { JSONParser.maxBytes = old }
        JSONParser.maxBytes = limit; body()
    }
    private func largeOnDisk(_ d: UserDefaults) -> [LargeKey: LargeLayout]? {
        d.data(forKey: LayoutStore.largeStoreKey).flatMap(LayoutStore.decodeLarge)
    }
    private func vibeID(_ s: LayoutStore) -> UUID { s.currentComputer!.modes.first { $0.name == "Vibe Coding" }!.id }
    private func large(_ s: LayoutStore, _ m: UUID) -> LayoutTarget { LayoutTarget(computer: s.currentComputerID, mode: m, set: .large) }
    private func original(_ s: LayoutStore, _ m: UUID) -> LayoutTarget { LayoutTarget(computer: s.currentComputerID, mode: m, set: .original) }

    /// 记录写入次数的 UserDefaults。
    final class CountingDefaults: UserDefaults {
        var writes: [String: Int] = [:]
        var watch: ((String) -> Void)?
        override func set(_ value: Any?, forKey key: String) { watch?("before:" + key); writes[key, default: 0] += 1; super.set(value, forKey: key); watch?("after:" + key) }
    }

    // 没有记录 = 还没生成; 第一次在内屏打开时生成并保存到独立 key; v5 主存档结构不变
    func testMissingMeansNotGeneratedAndEnsureGeneratesOnce() {
        let d = defaults("lg-ensure")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s)
        XCTAssertNil(d.data(forKey: LayoutStore.largeStoreKey), "全新安装: 没有大屏键位记录")
        XCTAssertNil(s.largeLayout(computer: s.currentComputerID, mode: m))
        XCTAssertEqual(s.layers(in: large(s, m)), [], "没生成时按目标取页得到空, 不拿默认数据冒充")
        let g = s.ensureLarge(computer: s.currentComputerID, mode: m)
        XCTAssertEqual(g, LargeLayoutGenerator.generate(from: s.mode(computer: s.currentComputerID, mode: m)!))
        XCTAssertEqual(largeOnDisk(d)?[LargeKey(computer: s.currentComputerID, mode: m)], g)
        // 主存档里没有任何大屏键位字段
        let v5 = String(data: d.data(forKey: "sidekey.app.v5")!, encoding: .utf8)!
        XCTAssertFalse(v5.contains("mouseButtons") || v5.contains("large"))
        // 重启后仍在
        XCTAssertEqual(LayoutStore(defaults: d).largeLayout(computer: s.currentComputerID, mode: m), g)
    }

    // 两个窗口同时第一次打开同一个模式: 只生成、保存一份 (§6.1 第 9 条)
    func testTwoWindowsTriggerOnlyOneGeneration() {
        let d = CountingDefaults(suiteName: "lg-two-windows")!; d.removePersistentDomain(forName: "lg-two-windows")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), c = s.currentComputerID
        d.writes = [:]
        let a = s.ensureLarge(computer: c, mode: m)          // 窗口 1
        let b = s.ensureLarge(computer: c, mode: m)          // 窗口 2 (同一个共享 store)
        XCTAssertEqual(a, b)
        XCTAssertEqual(d.writes["sidekey.app.v5"], 1, "只保存一次")
        XCTAssertEqual(s.large.count, 1)
    }

    // 已有记录 (哪怕是空页) 不会被生成覆盖: 「空布局」≠「还没生成」
    func testExistingEvenEmptyRecordNotRegenerated() {
        let d = defaults("lg-empty-record")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), c = s.currentComputerID
        s.ensureLarge(computer: c, mode: m)
        s.clearLayer(id: "base", in: large(s, m))
        XCTAssertEqual(s.layers(in: large(s, m)).first?.keys, [])
        let again = LayoutStore(defaults: d)
        XCTAssertEqual(again.ensureLarge(computer: c, mode: m)?.layers.first?.keys, [], "用户清空的大屏键位保留为空, 不重新生成")
        XCTAssertEqual(again.largeLayout(computer: c, mode: m)?.edited, true)
    }

    // 生成后原键位怎么改都不同步; 编辑过的大屏键位永远不会被自动覆盖; 两套互不影响 (§6.2、§6.3)
    func testSetsAreIndependentAndEditedLargeNeverOverwritten() {
        let d = defaults("lg-independent")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), c = s.currentComputerID
        s.ensureLarge(computer: c, mode: m)
        // 改大屏键位
        let added = s.addKey(layerID: "base", in: large(s, m))!
        // 改原键位 (外屏编辑)
        let origAdded = s.addKey(layerID: "base", in: original(s, m))!
        _ = s.addPage(in: original(s, m))
        XCTAssertFalse(s.layers(in: large(s, m)).flatMap(\.keys).contains { $0.id == origAdded }, "原键位的修改不进大屏键位")
        XCTAssertEqual(s.layers(in: large(s, m)).count, 1, "原键位加页不影响大屏键位")
        XCTAssertFalse(s.layers(in: original(s, m)).flatMap(\.keys).contains { $0.id == added }, "大屏键位的修改不进原键位")
        // 再「第一次打开」也不覆盖; 重启后也不覆盖
        s.ensureLarge(computer: c, mode: m)
        let reloaded = LayoutStore(defaults: d)
        reloaded.ensureLarge(computer: c, mode: m)
        XCTAssertTrue(reloaded.layers(in: large(reloaded, m)).flatMap(\.keys).contains { $0.id == added })
        XCTAssertEqual(reloaded.largeLayout(computer: c, mode: m)?.edited, true)
    }

    // 全部编辑接口都按明确目标作用在大屏键位上 (移动、改大小、改单键、删键、改列数、加页、页序、清空)
    func testAllEditOperationsTargetLargeSet() {
        let d = defaults("lg-edit-ops")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), c = s.currentComputerID, t = large(s, m)
        s.ensureLarge(computer: c, mode: m)
        let origBefore = s.layers(in: original(s, m))
        let space = s.layers(in: t)[0].keys.first { $0.label == "SPACE" }!
        XCTAssertTrue(s.moveKey(layerID: "base", capID: space.id, toCol: 0, toRow: 5, in: t))   // 出厂 Vibe 大屏 5 行已排满: 挪到新的第 5 行
        XCTAssertTrue(s.resizeKey(layerID: "base", capID: space.id, colSpan: 3, rowSpan: 1, in: t))
        var edited = s.layer("base", in: t)!.keys.first { $0.id == space.id }!; edited.label = "空格!"
        XCTAssertTrue(s.updateKey(layerID: "base", cap: edited, in: t))
        let dup = s.duplicateKey(layerID: "base", capID: space.id, in: t)!
        s.deleteKey(layerID: "base", capID: dup, in: t)
        s.setColumns(layerID: "base", 14, in: t)
        let p2 = s.addPage(in: t)!
        XCTAssertTrue(s.movePage(id: p2, by: -1, in: t))
        s.clearLayer(id: p2, in: t)
        let l = s.layers(in: t)
        XCTAssertEqual(l.map(\.id), [p2, "base"])
        XCTAssertEqual(l[1].columns, 14)
        XCTAssertEqual(l[1].keys.first { $0.id == space.id }.map { [$0.col, $0.row, $0.colSpan] }, [0, 5, 3])
        XCTAssertEqual(l[1].keys.first { $0.id == space.id }?.label, "空格!")
        XCTAssertEqual(s.layers(in: original(s, m)), origBefore, "原键位完全没变")
        XCTAssertEqual(largeOnDisk(d)?[LargeKey(computer: c, mode: m)]?.layers, l, "已保存")
        // 没生成时, 对大屏键位的编辑什么都不做
        let other = s.currentComputer!.modes.first { $0.name == "Codex Micro" }!.id
        XCTAssertNil(s.addKey(layerID: "base", in: large(s, other)))
        XCTAssertNil(s.largeLayout(computer: c, mode: other))
    }

    // 删页: 同一套里指向被删页的跳转键保留、变成「未设置目标」; 另一套不动 (§6.3)
    func testDeletePageUnsetsJumpKeysInSameSetOnly() {
        let d = defaults("lg-delete-page")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), c = s.currentComputerID
        let p2 = s.addPage(in: original(s, m))!
        // 原键位: base 上加一个跳到 p2 的键
        var jump = KeyCap(label: "→2", col: 0, row: 7, kind: .layer); jump.targetLayer = p2
        s.addKeyForTesting(jump, mode: m)
        s.ensureLarge(computer: c, mode: m)                       // 大屏键位也带上这个跳转键和 p2 页
        XCTAssertEqual(s.layer("base", in: large(s, m))?.keys.first { $0.id == jump.id }?.targetLayer, p2)
        s.deleteLayer(id: p2, in: large(s, m))
        XCTAssertNil(s.layer("base", in: large(s, m))?.keys.first { $0.id == jump.id }?.targetLayer, "大屏键位里的跳转键保留, 目标清空")
        XCTAssertTrue(s.layer("base", in: large(s, m))!.keys.contains { $0.id == jump.id }, "键本身保留")
        XCTAssertEqual(s.layer("base", in: original(s, m))?.keys.first { $0.id == jump.id }?.targetLayer, p2, "原键位不受影响")
        XCTAssertEqual(s.layers(in: original(s, m)).count, 2)
        // 原键位删页同样处理
        s.deleteLayer(id: p2, in: original(s, m))
        XCTAssertNil(s.layer("base", in: original(s, m))?.keys.first { $0.id == jump.id }?.targetLayer)
    }

    // 删除模式、删除电脑: 两套一起删, 存档里的大屏键位也清掉
    func testDeleteModeAndComputerRemoveLarge() {
        let d = defaults("lg-delete-mode")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let modes = s.currentComputer!.modes.map(\.id)
        for m in modes { s.ensureLarge(computer: c, mode: m) }
        XCTAssertEqual(largeOnDisk(d)?.count, 3)
        s.deleteMode(id: modes[1])
        XCTAssertNil(s.largeLayout(computer: c, mode: modes[1]))
        XCTAssertEqual(Set(largeOnDisk(d)!.keys.map(\.mode)), [modes[0], modes[2]])
        // 第二台电脑, 生成后删掉这台电脑
        let b = Computer.make(name: "B", host: "10.0.0.2")
        XCTAssertTrue(s.addComputer(b))
        let second = b.id
        let m2 = s.computer(second)!.modes[0].id
        s.ensureLarge(computer: second, mode: m2)
        XCTAssertNotNil(largeOnDisk(d)?[LargeKey(computer: second, mode: m2)])
        XCTAssertTrue(s.deleteComputer(id: second))
        XCTAssertNil(largeOnDisk(d)?[LargeKey(computer: second, mode: m2)])
        XCTAssertEqual(largeOnDisk(d)?.count, 2)
    }

    // 复制模式 / 复制到其他电脑: 两套一起复制 (键 id 换新、页 id 不变、内容相同); 大屏键位没生成就不复制
    func testDuplicateModeCopiesLargeWhenGenerated() {
        let d = defaults("lg-duplicate")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let vibe = vibeID(s)
        let codex = s.currentComputer!.modes.first { $0.name == "Codex Micro" }!.id
        s.ensureLarge(computer: c, mode: vibe)
        _ = s.addKey(layerID: "base", in: large(s, vibe))                // 编辑过的大屏键位
        let src = s.largeLayout(computer: c, mode: vibe)!
        // 同一台电脑
        let copy = s.duplicateMode(id: vibe)!
        let cl = s.largeLayout(computer: c, mode: copy)!
        XCTAssertEqual(cl.layers.map(\.id), src.layers.map(\.id))
        XCTAssertEqual(cl.layers.map { $0.keys.map(\.label) }, src.layers.map { $0.keys.map(\.label) })
        XCTAssertTrue(Set(cl.layers.flatMap(\.keys).map(\.id)).isDisjoint(with: src.layers.flatMap(\.keys).map(\.id)), "键 id 全部换新")
        XCTAssertTrue(Set(cl.mouseButtons.map(\.id)).isDisjoint(with: src.mouseButtons.map(\.id)))
        XCTAssertEqual(cl.edited, src.edited)
        // 跨电脑
        let other = Computer.make(name: "B", host: "10.0.0.3")
        XCTAssertTrue(s.addComputer(other))
        let c2 = other.id
        XCTAssertNotEqual(c2, c)
        _ = s.selectComputer(c)
        let copy2 = s.duplicateMode(id: vibe, toComputer: c2)!
        XCTAssertEqual(s.largeLayout(computer: c2, mode: copy2)?.layers.map { $0.keys.map(\.label) }, src.layers.map { $0.keys.map(\.label) })
        // 没生成的模式: 不复制大屏键位
        let copy3 = s.duplicateMode(id: codex)!
        XCTAssertNil(s.largeLayout(computer: c, mode: copy3))
        // 都已保存
        let r = LayoutStore(defaults: d)
        XCTAssertNotNil(r.largeLayout(computer: c, mode: copy)); XCTAssertNotNil(r.largeLayout(computer: c2, mode: copy2)); XCTAssertNil(r.largeLayout(computer: c, mode: copy3))
    }

    // 重置模式: 二选一 (§6.3)
    func testResetScopes() {
        let d = defaults("lg-reset")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        s.ensureLarge(computer: c, mode: m)
        let lAdd = s.addKey(layerID: "base", in: large(s, m))!
        let oAdd = s.addKey(layerID: "base", in: original(s, m))!
        // 只重置原键位: 大屏键位不变
        s.resetMode(original(s, m), scope: .currentSet)
        XCTAssertFalse(s.layers(in: original(s, m)).flatMap(\.keys).contains { $0.id == oAdd })
        XCTAssertTrue(s.layers(in: large(s, m)).flatMap(\.keys).contains { $0.id == lAdd })
        // 只重置大屏键位: 按当前原键位重新生成, 原键位不变
        let oAdd2 = s.addKey(layerID: "base", in: original(s, m))!
        s.resetMode(large(s, m), scope: .currentSet)
        XCTAssertEqual(s.largeLayout(computer: c, mode: m), LargeLayoutGenerator.generate(from: s.mode(computer: c, mode: m)!))
        XCTAssertTrue(s.layers(in: large(s, m)).flatMap(\.keys).contains { $0.id == oAdd2 }, "按现在的原键位生成")
        XCTAssertTrue(s.layers(in: original(s, m)).flatMap(\.keys).contains { $0.id == oAdd2 }, "原键位不变")
        // 两套都重置: 原键位恢复初始, 大屏键位回到「还没生成」(存档里也没有)
        s.resetMode(large(s, m), scope: .both)
        XCTAssertNil(s.largeLayout(computer: c, mode: m))
        XCTAssertNil(largeOnDisk(d)?[LargeKey(computer: c, mode: m)])
        XCTAssertEqual(s.layers(in: original(s, m)).map { $0.keys.map(\.label) }, BuiltinModes.vibe().layers.map { $0.keys.map(\.label) })
    }

    // 「从原键位重新生成」: 替换编辑, edited 复位
    func testRegenerate() {
        let d = defaults("lg-regen")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        s.ensureLarge(computer: c, mode: m)
        _ = s.addKey(layerID: "base", in: large(s, m))
        XCTAssertTrue(s.regenerateLarge(computer: c, mode: m))
        XCTAssertEqual(s.largeLayout(computer: c, mode: m), LargeLayoutGenerator.generate(from: s.mode(computer: c, mode: m)!))
        XCTAssertEqual(LayoutStore(defaults: d).largeLayout(computer: c, mode: m)?.edited, false)
    }

    // 笔记本键盘模式不生成大屏键位 (§4.9)
    func testLaptopModeNeverGenerates() {
        let d = defaults("lg-laptop")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let id = s.addMode(named: "L")!
        s.setModeKindForTesting(id, .laptopKeyboard)
        XCTAssertNil(s.ensureLarge(computer: c, mode: id))
        XCTAssertNil(s.largeLayout(computer: c, mode: id))
    }

    // MARK: T-DATA-3 [M2]: 大屏键位存档写坏 → 不覆盖原始数据, 进恢复流程; 主存档照常

    private func assertLargeRecovers(_ raw: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let d = defaults("lg-corrupt-" + name)
        let seed = LayoutStore(defaults: d)
        let c = seed.currentComputerID, m = vibeID(seed)
        d.set(raw, forKey: LayoutStore.largeStoreKey)
        let s = LayoutStore(defaults: d)
        XCTAssertNil(s.recovery, "\(name): 主存档不受影响", file: file, line: line)
        XCTAssertEqual(s.largeRecovery?.rawData, raw, "\(name): 进入大屏键位的恢复流程", file: file, line: line)
        XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), raw, "\(name): 启动时不改写", file: file, line: line)
        XCTAssertTrue(LayoutStore.corruptBackupKeys(in: d, prefix: LayoutStore.largeCorruptPrefix).contains { d.data(forKey: $0) == raw }, "\(name): 有备份", file: file, line: line)
        XCTAssertNil(s.ensureLarge(computer: c, mode: m), "\(name): 恢复期间不生成", file: file, line: line)
        _ = s.addPage()                                                      // 主存档照常保存
        XCTAssertFalse(s.hasUnsavedChanges, file: file, line: line)
        XCTAssertEqual(s.layers(in: s.currentTarget).count, 2, file: file, line: line)
        XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), raw, "\(name): 主存档保存时大屏键位的原始数据不被覆盖", file: file, line: line)
        XCTAssertEqual(LayoutStore(defaults: d).largeRecovery?.rawData, raw, "\(name): 重启后仍在恢复流程", file: file, line: line)
        s.resolveLargeRecoveryWithFreshData()
        XCTAssertNil(s.largeRecovery, file: file, line: line)
        XCTAssertNotEqual(d.data(forKey: LayoutStore.largeStoreKey), raw, "\(name): 用户选择继续后才写新数据", file: file, line: line)
        XCTAssertNotNil(s.ensureLarge(computer: c, mode: m), file: file, line: line)
        XCTAssertTrue(LayoutStore.corruptBackupKeys(in: d, prefix: LayoutStore.largeCorruptPrefix).contains { d.data(forKey: $0) == raw }, "\(name): 备份仍在", file: file, line: line)
    }

    func testCorruptLargeStoreEntersRecoveryWithoutOverwriting() throws {
        assertLargeRecovers(Data("not json".utf8), "garbage")
        assertLargeRecovers(Data(#"{"v":1,"entries":{"x":"#.utf8), "truncated")
        assertLargeRecovers(Data(#"{"v":2,"entries":{}}"#.utf8), "future-version")
        assertLargeRecovers(Data(#"{"v":1,"entries":{"not-a-key":{"layers":[],"mouseButtons":[],"edited":false}}}"#.utf8), "bad-index")
        // 结构不合法: 一页都没有 / 鼠标键不是左右各一
        let c = UUID(), m = UUID()
        let empty = #"{"v":1,"entries":{"\#(c.uuidString)/\#(m.uuidString)":{"layers":[],"mouseButtons":[],"edited":false}}}"#
        assertLargeRecovers(Data(empty.utf8), "no-pages")
        assertLargeRecovers(Data([0xFF, 0xFE, 0x00]), "bad-utf8")
        // B2: 同一个电脑 + 模式的索引出现两次 (UUID 大小写不同)
        let g = LargeLayoutGenerator.generate(from: BuiltinModes.vibe())!
        var g2 = g; g2.edited = true
        let k = "\(c.uuidString)/\(m.uuidString)"
        assertLargeRecovers(try SidekeyJSON.encode(LayoutStore.LargeFile(v: 1, entries: [k: g, k.lowercased(): g2])), "case-duplicate-index")
        // B2: 几何数值会溢出 / 超出上限
        for (label, mutate) in [("row-int-max", { (x: inout KeyCap) in x.row = Int.max }), ("span-huge", { (x: inout KeyCap) in x.rowSpan = 1_000_000 }),
                                ("negative-col", { (x: inout KeyCap) in x.col = -1 })] {
            var bad = g; mutate(&bad.layers[0].keys[0])
            assertLargeRecovers(try SidekeyJSON.encode(LayoutStore.LargeFile(v: 1, entries: [k: bad])), label)
        }
        var wide = g; wide.layers[0].columns = 100_000
        assertLargeRecovers(try SidekeyJSON.encode(LayoutStore.LargeFile(v: 1, entries: [k: wide])), "columns-huge")
        // 提交依据不合法
        assertLargeRecovers(Data(#"{"v":1,"entries":{},"pending":{"main":"x","drop":[]}}"#.utf8), "bad-pending")
    }

    // B2: key 存在但不是 Data (字符串、数字): 不能当成「没有存档」去覆盖, 进恢复流程, 原值保留
    func testNonDataLargeValueEntersRecoveryAndIsKept() {
        for (name, value) in [("string", "broken-value" as Any), ("number", 42 as Any)] {
            let d = defaults("lg-nondata-" + name)
            let seed = LayoutStore(defaults: d)
            let m = vibeID(seed)
            d.set(value, forKey: LayoutStore.largeStoreKey)
            let s = LayoutStore(defaults: d)
            XCTAssertNotNil(s.largeRecovery, name)
            XCTAssertNil(s.ensureLarge(computer: s.currentComputerID, mode: m), name)
            _ = s.addPage()
            XCTAssertFalse(s.hasUnsavedChanges, name)
            XCTAssertEqual(d.object(forKey: LayoutStore.largeStoreKey) as? NSObject, value as? NSObject, "\(name): 原值不被覆盖")
            XCTAssertFalse(LayoutStore.corruptBackupKeys(in: d, prefix: LayoutStore.largeCorruptPrefix).isEmpty, name)
        }
    }

    // B2 兜底: 就算异常坐标进了内存, 行数计算也不会整数溢出崩溃
    func testRowCountSaturatesInsteadOfOverflowing() {
        let l = KeyLayer(id: "x", columns: 1, keys: [KeyCap(label: "Bad", row: Int.max, rowSpan: 5)])
        XCTAssertEqual(l.rowCount, Int.max)
    }

    // I1: 复制含未知类型键的模式 → 保存 → 重载: 副本里的未知键保持新 id (原键位和大屏键位都要), 原键的原始数据不变
    func testCopiedUnknownKeyKeepsNewIDAfterReload() throws {
        let d = defaults("lg-unknown-copy")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        let raw = #"{"kind":"futureAudit","id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","row":9,"col":0,"nested":{"big":123456789012345678901234567890,"a":[1.00,null]}}"#
        let u = try SidekeyJSON.decode(KeyCap.self, from: Data(raw.utf8))
        s.addKeyForTesting(u, mode: m)
        s.ensureLarge(computer: c, mode: m)
        let n = try XCTUnwrap(s.duplicateMode(id: m))
        let copiedOrig = try XCTUnwrap(s.layers(in: original(s, n)).flatMap(\.keys).first { $0.kind == .unknown })
        let copiedLarge = try XCTUnwrap(s.layers(in: large(s, n)).flatMap(\.keys).first { $0.kind == .unknown })
        XCTAssertNotEqual(copiedOrig.id, u.id); XCTAssertNotEqual(copiedLarge.id, u.id)
        // 同一页里复制键也一样
        let dup = try XCTUnwrap(s.duplicateKey(layerID: "base", capID: u.id, in: original(s, m)))
        let r = LayoutStore(defaults: d)
        XCTAssertEqual(r.layers(in: LayoutTarget(computer: c, mode: n, set: .original)).flatMap(\.keys).first { $0.kind == .unknown }?.id, copiedOrig.id)
        XCTAssertEqual(r.layers(in: LayoutTarget(computer: c, mode: n, set: .large)).flatMap(\.keys).first { $0.kind == .unknown }?.id, copiedLarge.id)
        XCTAssertTrue(r.layers(in: LayoutTarget(computer: c, mode: m, set: .original)).flatMap(\.keys).contains { $0.id == dup })
        // 原键: id 和原始数据原文不变 (大数字、1.00 原样)
        let orig = try XCTUnwrap(r.layers(in: LayoutTarget(computer: c, mode: m, set: .original)).flatMap(\.keys).first { $0.id == u.id })
        XCTAssertEqual(orig.rawUnknown?.tree, u.rawUnknown?.tree)
        let text = String(decoding: d.data(forKey: "sidekey.app.v5")!, as: UTF8.self)
        XCTAssertTrue(text.contains("123456789012345678901234567890")); XCTAssertTrue(text.contains("1.00"))
    }

    // MARK: T-DATA-2: 新版之间降级

    /// 模拟「装回较旧的新版」: 旧版只认 v5 主存档, 不认识 sidekey.large.v1 (原样留着)。旧版期间: 改原键位、删一个模式、新建一个模式。
    func testDowngradeBetweenNewVersions() throws {
        let d = defaults("lg-downgrade")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let modes = s.currentComputer!.modes.map(\.id)      // Vibe, 键盘, Codex Micro
        for m in modes { s.ensureLarge(computer: c, mode: m) }
        _ = s.addKey(layerID: "base", in: large(s, modes[0]))                    // 大屏键位编辑过
        let largeBefore = s.large
        let largeRaw = d.data(forKey: LayoutStore.largeStoreKey)!

        // —— 旧版运行期间: 只读写 v5 (用解码 → 修改 → 编码模拟), 不碰大屏键位的 key
        var p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: d.data(forKey: "sidekey.app.v5")!)
        let ci = p.computers.firstIndex { $0.id == c }!
        p.computers[ci].modes[0].layers[0].keys.append(KeyCap(label: "旧版加的", code: "a", col: 0, row: 9))
        p.computers[ci].modes.removeAll { $0.id == modes[1] }                    // 删掉「vibecoding键盘模式」
        let newMode = Mode.makeDefault(name: "旧版新建")
        p.computers[ci].modes.append(newMode)
        d.set(try SidekeyJSON.encode(p), forKey: "sidekey.app.v5")
        XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), largeRaw, "旧版不碰大屏键位")

        // —— 回到新版
        let back = LayoutStore(defaults: d)
        XCTAssertTrue(back.layers(in: original(back, modes[0])).flatMap(\.keys).contains { $0.label == "旧版加的" }, "原键位保留降级期间的修改")
        XCTAssertNil(back.largeLayout(computer: c, mode: modes[1]), "被删模式的大屏键位已清理")
        XCTAssertEqual(back.largeLayout(computer: c, mode: modes[0]), largeBefore[LargeKey(computer: c, mode: modes[0])], "其他模式的大屏键位原样保留 (含编辑)")
        XCTAssertEqual(back.largeLayout(computer: c, mode: modes[2]), largeBefore[LargeKey(computer: c, mode: modes[2])])
        XCTAssertFalse(back.layers(in: large(back, modes[0])).flatMap(\.keys).contains { $0.label == "旧版加的" }, "降级期间原键位的修改不同步到大屏键位")
        XCTAssertNil(back.largeLayout(computer: c, mode: newMode.id), "旧版期间新建的模式: 还没生成")
        XCTAssertNotNil(back.ensureLarge(computer: c, mode: newMode.id), "第一次进内屏时生成")
        let disk = try XCTUnwrap(largeOnDisk(d))
        XCTAssertNil(disk[LargeKey(computer: c, mode: modes[1])], "清理也落盘")
        XCTAssertEqual(disk.count, 3)
    }

    /// T-DATA-2 最后一条在大屏键位里的部分: Codex Micro 的 .window / .agentSlot 键随大屏键位来回读写不丢
    func testCodexMicroLargeLayoutRoundTrips() {
        let d = defaults("lg-codex")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let codex = s.currentComputer!.modes.first { $0.name == "Codex Micro" }!.id
        let g = s.ensureLarge(computer: c, mode: codex)!
        XCTAssertTrue(g.layers.flatMap(\.keys).contains { $0.kind == .agentSlot && $0.slot != nil })
        XCTAssertEqual(LayoutStore(defaults: d).largeLayout(computer: c, mode: codex), g)
    }

    // 主存档进恢复流程时: 大屏键位既不按默认数据清理, 也不写
    func testMainStoreRecoveryLeavesLargeUntouched() {
        let d = defaults("lg-main-recovery")
        let s = LayoutStore(defaults: d)
        s.ensureLarge(computer: s.currentComputerID, mode: vibeID(s))
        let raw = d.data(forKey: LayoutStore.largeStoreKey)!
        d.set(Data("broken".utf8), forKey: "sidekey.app.v5")
        let r = LayoutStore(defaults: d)
        XCTAssertNotNil(r.recovery)
        XCTAssertEqual(r.large.count, 1, "不按恢复用的默认数据清理")
        XCTAssertNil(r.ensureLarge(computer: r.currentComputerID, mode: r.currentModeID), "恢复期间不生成")
        _ = r.addPage()
        XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), raw)
    }

    // MARK: 保存失败保留草稿 (§6.4 第 7 条) —— 大屏键位同一套规则

    /// 让一套大屏键位变大 (发送文本 5000 字), 用来在主存档放得下的前提下, 只靠大屏存档把合计推过上限。
    private func bulky(_ s: LayoutStore, _ m: UUID, size: Int = 5000) {
        s.ensureLarge(computer: s.currentComputerID, mode: m)
        var k = s.layers(in: large(s, m))[0].keys[0]
        k.sendText = String(repeating: "x", count: size)
        XCTAssertTrue(s.updateKey(layerID: s.layers(in: large(s, m))[0].id, cap: k, in: large(s, m)))
    }

    // I6: 真正的「只因大屏存档超限」—— 主存档本身远在上限之下, 合计超限
    func testLargeOnlyOverflowKeepsDraftDiscardAndAutoRetry() {
        let d = defaults("lg-large-only-overflow")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        bulky(s, m)
        let v5 = d.data(forKey: "sidekey.app.v5")!, lraw = d.data(forKey: LayoutStore.largeStoreKey)!
        let before = s.largeLayout(computer: c, mode: m)
        XCTAssertGreaterThan(lraw.count, 5000)
        var added: UUID?
        withLimit(v5.count + lraw.count + 500) {
            XCTAssertLessThan(v5.count, JSONParser.maxBytes / 2, "前提: 主存档自己远在上限之下")
            added = s.addKey(layerID: "base", in: large(s, m))                // 合计仍放得下
            XCTAssertFalse(s.hasUnsavedChanges)
            var k = s.layers(in: large(s, m))[0].keys.first { $0.id == added }!
            k.sendText = String(repeating: "y", count: 400)                   // 只有大屏存档变大 → 合计超限
            XCTAssertTrue(s.updateKey(layerID: "base", cap: k, in: large(s, m)))
            XCTAssertTrue(s.hasUnsavedChanges, "合计超限: 保存失败, 保留草稿")
            XCTAssertEqual(s.layers(in: large(s, m))[0].keys.first { $0.id == added }?.sendText?.count, 400, "修改照常生效")
            XCTAssertNotEqual(d.data(forKey: LayoutStore.largeStoreKey), lraw)        // 上一次 (合计放得下) 已保存
            let committedLarge = d.data(forKey: LayoutStore.largeStoreKey)
            k.sendText = nil
            XCTAssertTrue(s.updateKey(layerID: "base", cap: k, in: large(s, m)))
            XCTAssertFalse(s.hasUnsavedChanges, "数据变小后自动保存成功")
            XCTAssertNotEqual(d.data(forKey: LayoutStore.largeStoreKey), committedLarge)
        }
        // 放弃修改
        withLimit(v5.count + lraw.count + 500) {
            var k = s.layers(in: large(s, m))[0].keys.first { $0.id == added }!
            k.sendText = String(repeating: "z", count: 400)
            _ = s.updateKey(layerID: "base", cap: k, in: large(s, m))
            XCTAssertTrue(s.hasUnsavedChanges)
            s.discardUnsavedChanges()
            XCTAssertNil(s.layers(in: large(s, m))[0].keys.first { $0.id == added }?.sendText)
        }
        _ = before
        // 未保存期间生成的大屏键位, 放弃后回到「还没生成」
        let codex = s.currentComputer!.modes.first { $0.name == "Codex Micro" }!.id
        withLimit(10) { _ = s.ensureLarge(computer: c, mode: codex) }
        XCTAssertNotNil(s.largeLayout(computer: c, mode: codex))
        s.discardUnsavedChanges()
        XCTAssertNil(s.largeLayout(computer: c, mode: codex))
    }

    // I5: 合计上限 —— 两个存档各自都放得下、合计放不下时保存失败, 两个存档都不动
    func testCombinedSizeLimit() {
        let d = defaults("lg-combined")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s)
        bulky(s, m)
        let v5 = d.data(forKey: "sidekey.app.v5")!, lraw = d.data(forKey: LayoutStore.largeStoreKey)!
        withLimit(max(v5.count, lraw.count) + 200) {
            _ = s.addPage()
            XCTAssertTrue(s.hasUnsavedChanges, "各自都在上限内, 但合计超限")
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), v5)
            XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), lraw)
        }
        XCTAssertTrue(s.retryUnsavedSave())
    }

    // B1: 中间形态 (新 ∪ 被移除的旧) 放不下时, 整次保存失败 (不能跳过那一步写入)
    func testIntermediateFormOverflowKeepsDraftInsteadOfSkipping() throws {
        let d = defaults("lg-superset-overflow")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID
        let a = vibeID(s)
        bulky(s, a)
        let v5 = d.data(forKey: "sidekey.app.v5")!, lraw = d.data(forKey: LayoutStore.largeStoreKey)!
        var b: UUID!
        withLimit(1) { b = s.duplicateMode(id: a); s.deleteMode(id: a) }          // 复制 A 得到 B, 再删 A (都未保存)
        XCTAssertTrue(s.hasUnsavedChanges)
        // 上限: 最终形态 (只有 B) 放得下, 中间形态 (A + B) 放不下
        let final = try XCTUnwrap(LayoutStore.encodeLarge(s.large))
        let limit = v5.count + final.count + 1500
        XCTAssertLessThan(limit, v5.count + lraw.count + final.count, "前提: 中间形态 A+B 超限")
        withLimit(limit) {
            XCTAssertFalse(s.retryUnsavedSave(), "中间形态放不下: 保存失败, 不跳过")
            XCTAssertTrue(s.hasUnsavedChanges)
            XCTAssertEqual(d.data(forKey: "sidekey.app.v5"), v5, "主存档没动")
            XCTAssertEqual(d.data(forKey: LayoutStore.largeStoreKey), lraw, "大屏存档没动")
        }
        // 上限足够时提交; 任何写入点崩溃, B 编辑过的大屏键位都不丢
        XCTAssertTrue(s.retryUnsavedSave())
        XCTAssertNotNil(LayoutStore(defaults: d).largeLayout(computer: c, mode: b))
    }

    // MARK: 逐个写入点回放 (主存档、大屏存档、凭证记录、回收队列、Keychain 一起恢复)

    /// 每次 UserDefaults 写入 / 删除前后、每次 Keychain 写入 / 删除后, 记下所有 sidekey.* 的值和相关 Keychain 项。
    final class SnapshotDefaults: UserDefaults {
        var observe: ((String) -> Void)?
        override func set(_ value: Any?, forKey key: String) { observe?("before:" + key); super.set(value, forKey: key); observe?("after:" + key) }
        override func removeObject(forKey key: String) { observe?("before-remove:" + key); super.removeObject(forKey: key); observe?("after-remove:" + key) }
    }
    struct Shot { let ev: String; let defaults: [String: Any]; let keychain: [String: String] }

    func testEveryWriteCheckpointIncludingKeychainLoadsConsistently() throws {
        for op in ["edit", "deleteMode", "pairAndCopy", "resetBoth", "clearTokenAndDeleteMode", "deleteComputer", "fallback"] {
            let name = "lg-trace-" + op
            let d = SnapshotDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
            let s = LayoutStore(defaults: d)
            let c = s.currentComputerID
            let b = Computer.make(name: "B", host: "old-b", token: "OLD-B")
            XCTAssertTrue(s.addComputer(b))
            _ = s.selectComputer(c)
            _ = s.updateComputerConnection(id: c, host: "old-a", port: 1, token: "OLD-A")
            let modes = s.currentComputer!.modes.map(\.id)
            for m in modes { s.ensureLarge(computer: c, mode: m) }
            s.ensureLarge(computer: b.id, mode: b.modes[0].id)
            _ = s.addKey(layerID: "base", in: large(s, modes[0]))                    // 被操作的模式的大屏键位编辑过
            let before = s.large, oldMain = d.data(forKey: "sidekey.app.v5")!
            let ids = [c, b.id]
            defer { for id in ids { KeychainToken.deleteAll(id: id.uuidString) }; KeychainToken.observe = nil; KeychainToken.faultSet = nil }

            var shots: [Shot] = []
            var busy = false
            let capture: (String) -> Void = { ev in
                guard !busy else { return }; busy = true; defer { busy = false }
                var kc: [String: String] = [:]
                for id in ids { for a in [id.uuidString] + (KeychainToken.accounts(prefix: id.uuidString + "@") ?? []) { if let t = KeychainToken.get(a) { kc[a] = t } } }
                shots.append(Shot(ev: ev, defaults: d.dictionaryRepresentation().filter { $0.key.hasPrefix("sidekey.") }, keychain: kc))
            }
            // 先做成未保存的修改, 再一次重试保存, 回放这一次保存的每个写入点
            var copied: UUID?
            withLimit(1) {
                switch op {
                case "edit": _ = s.addKey(layerID: "base", in: large(s, modes[0]))
                case "deleteMode": s.deleteMode(id: modes[0])
                case "pairAndCopy", "fallback": _ = s.updateComputerConnection(id: c, host: "new-a", port: 2, token: "NEW-A"); copied = s.duplicateMode(id: modes[0])
                case "resetBoth": s.resetMode(large(s, modes[0]), scope: .both)
                case "clearTokenAndDeleteMode": _ = s.updateComputerConnection(id: c, host: "clear-a", port: 2, token: ""); s.deleteMode(id: modes[0])
                default: XCTAssertTrue(s.deleteComputer(id: c)); _ = s.updateComputerConnection(id: b.id, host: "new-b", port: 2, token: "NEW-B")
                }
            }
            XCTAssertTrue(s.hasUnsavedChanges, op)
            if op == "fallback" { KeychainToken.faultSet = { $0.hasPrefix(c.uuidString + "@") ? false : nil } }
            d.observe = capture; KeychainToken.observe = capture
            XCTAssertTrue(s.retryUnsavedSave(), op)
            d.observe = nil; KeychainToken.observe = nil; KeychainToken.faultSet = nil
            let newMain = d.data(forKey: "sidekey.app.v5")!
            XCTAssertGreaterThan(shots.count, 5, op)

            for shot in shots {
                for id in ids { KeychainToken.deleteAll(id: id.uuidString) }
                for (a, t) in shot.keychain { XCTAssertTrue(KeychainToken.set(t, for: a)) }
                let rn = name + ".replay"
                let r = UserDefaults(suiteName: rn)!; r.removePersistentDomain(forName: rn)
                for (k, v) in shot.defaults { r.set(v, forKey: k) }
                let main = try XCTUnwrap(shot.defaults["sidekey.app.v5"] as? Data)
                let isOld = main == oldMain
                XCTAssertTrue(isOld || main == newMain, "\(op) \(shot.ev)")
                let loaded = LayoutStore(defaults: r)
                XCTAssertNil(loaded.recovery, "\(op) \(shot.ev)"); XCTAssertNil(loaded.largeRecovery, "\(op) \(shot.ev)")
                // 凭证
                if op == "deleteComputer" && !isOld {
                    XCTAssertNil(loaded.computer(c)); XCTAssertEqual(loaded.computer(b.id)?.token, "NEW-B", "\(op) \(shot.ev)")
                } else {
                    let changed = !isOld && ["pairAndCopy", "fallback", "clearTokenAndDeleteMode"].contains(op)
                    XCTAssertEqual(loaded.computer(c)?.token, changed ? (op == "clearTokenAndDeleteMode" ? "" : "NEW-A") : "OLD-A", "\(op) \(shot.ev)")
                    XCTAssertEqual(loaded.computer(b.id)?.token, "OLD-B", "\(op) \(shot.ev)")
                }
                // 大屏键位: 旧主存档 → 与操作前完全一致 (编辑操作允许已是新内容); 新主存档 → 与操作后一致
                for (key, value) in before {
                    let actual = loaded.largeLayout(computer: key.computer, mode: key.mode)
                    let target = key.mode == modes[0] && key.computer == c
                    if isOld {
                        if op == "edit" && target { XCTAssertTrue(actual == value || actual?.layers[0].keys.count == value.layers[0].keys.count + 1, "\(op) \(shot.ev)") }
                        else { XCTAssertEqual(actual, value, "\(op) \(shot.ev): 旧主存档配旧的大屏键位") }
                    } else {
                        let gone = (target && ["deleteMode", "resetBoth", "clearTokenAndDeleteMode"].contains(op)) || (op == "deleteComputer" && key.computer == c)
                        if gone { XCTAssertNil(actual, "\(op) \(shot.ev): 已删除 / 已重置的大屏键位不能复活") }
                        else if op == "edit" && target { XCTAssertEqual(actual?.layers[0].keys.count, value.layers[0].keys.count + 1, "\(op) \(shot.ev)") }
                        else { XCTAssertEqual(actual, value, "\(op) \(shot.ev)") }
                    }
                }
                if !isOld, let copied { XCTAssertNotNil(loaded.largeLayout(computer: c, mode: copied), "\(op) \(shot.ev): 复制出来的大屏键位不丢") }
                XCTAssertTrue(loaded.large.keys.allSatisfy { loaded.mode(computer: $0.computer, mode: $0.mode) != nil }, "\(op) \(shot.ev)")
            }
        }
    }

    // MARK: 第二轮审计: 几何范围读写一致 (B1/I2)、提交依据格式 (I3)、提交前中断 + 旧版改档 (I1)

    // B1: 编辑接口不能写出超出范围的键; App 自己写出的大屏存档一定读得回来
    func testEditsCannotLeaveBoundsAndWrittenLargeIsReadable() throws {
        let d = defaults("lg-bounds-edit")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        let cap = s.layers(in: original(s, m))[0].keys.first { $0.kind == .normal }!
        XCTAssertFalse(s.moveKey(layerID: "base", capID: cap.id, toCol: 0, toRow: 10_001, in: original(s, m)), "挪到第 10001 行: 拒绝")
        XCTAssertFalse(s.resizeKey(layerID: "base", capID: cap.id, colSpan: 1, rowSpan: 10_001, in: original(s, m)))
        var far = cap; far.row = 20_000
        XCTAssertFalse(s.updateKey(layerID: "base", cap: far, in: original(s, m)), "改单键也不能把位置改出范围")
        var wide = cap; wide.col = 11; wide.colSpan = 4                              // 12 列网格: 11 + 4 > 12
        XCTAssertFalse(s.updateKey(layerID: "base", cap: wide, in: original(s, m)))
        XCTAssertNotNil(s.ensureLarge(computer: c, mode: m))
        let lc = s.layers(in: large(s, m))[0].keys[0]
        XCTAssertFalse(s.moveKey(layerID: "base", capID: lc.id, toCol: 0, toRow: 10_001, in: large(s, m)))
        let raw = try XCTUnwrap(d.data(forKey: LayoutStore.largeStoreKey))
        XCTAssertNotNil(LayoutStore.decodeLarge(raw))
        XCTAssertNil(LayoutStore(defaults: d).largeRecovery)
    }

    // B1: 原键位里已有超出范围的旧数据 → 原键位照常保留可用; 不生成大屏键位 (不裁、不挪); 原因可查
    func testLegacyOutOfBoundsKeysBlockGenerationButStayUsable() {
        let d = defaults("lg-bounds-legacy")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        let legacy = KeyCap(label: "旧", code: "a", col: 0, row: 10_001)
        s.addKeyForTesting(legacy, mode: m)
        XCTAssertFalse(s.hasUnsavedChanges, "主存档照常保存 (不按大屏范围拒绝原键位的旧数据)")
        XCTAssertNil(s.ensureLarge(computer: c, mode: m))
        XCTAssertEqual(s.largeUnavailableReason(computer: c, mode: m), .outOfBounds)
        XCTAssertNil(s.largeLayout(computer: c, mode: m))
        let r = LayoutStore(defaults: d)
        XCTAssertEqual(r.layers(in: LayoutTarget(computer: c, mode: m, set: .original)).flatMap(\.keys).first { $0.id == legacy.id }?.row, 10_001, "不裁、不挪")
        XCTAssertNil(r.largeRecovery)
        // 其他键照常可编辑
        XCTAssertNotNil(r.addKey(layerID: "base", in: LayoutTarget(computer: c, mode: m, set: .original)))
        // 去掉那个键之后就能生成
        r.deleteKey(layerID: "base", capID: legacy.id, in: LayoutTarget(computer: c, mode: m, set: .original))
        XCTAssertNotNil(r.ensureLarge(computer: c, mode: m))
    }

    // I2: 网格外的键 (列越界) 读不进来; 读写同一套校验
    func testOffGridKeyRejectedOnLoad() throws {
        var g = LargeLayoutGenerator.generate(from: BuiltinModes.vibe())!
        g.layers[0].columns = 1
        g.layers[0].keys = [KeyCap(label: "X", col: 1, row: 0)]
        XCTAssertFalse(LayoutStore.isStructurallyValid(g))
        XCTAssertNil(LayoutStore.encodeLarge([LargeKey(computer: UUID(), mode: UUID()): g]), "写不出自己读不回来的存档")
    }

    // I3: 提交依据的哈希必须是 64 位小写十六进制
    func testPendingHashMustBeLowercaseHex() throws {
        let g = LargeLayoutGenerator.generate(from: BuiltinModes.vibe())!
        let k = LargeKey(computer: UUID(), mode: UUID())
        for bad in [String(repeating: "g", count: 64), String(repeating: "A", count: 64), String(repeating: "0", count: 63), String(repeating: "0", count: 63) + "é"] {
            let raw = try SidekeyJSON.encode(LayoutStore.LargeFile(v: 1, entries: [k.raw: g], pending: LargePending(main: bad, drop: [k.raw])))
            XCTAssertNil(LayoutStore.decodeLargeFile(raw), bad)
        }
        let ok = try SidekeyJSON.encode(LayoutStore.LargeFile(v: 1, entries: [k.raw: g], pending: LargePending(main: LayoutStore.blobHash(Data("x".utf8)), drop: [k.raw])))
        XCTAssertNotNil(LayoutStore.decodeLargeFile(ok))
    }

    // I1 (§6.4 第 5 条「不保证的组合」的另一面): 「两套都重置」在主存档提交前中断, 接着旧版改写主存档 → 提交前仍有效的大屏编辑保留, 不丢
    func testInterruptBeforeMainCommitThenOlderVersionRewriteKeepsEdits() throws {
        let name = "lg-precommit-downgrade"
        let d = SnapshotDefaults(suiteName: name)!; d.removePersistentDomain(forName: name)
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        s.ensureLarge(computer: c, mode: m)
        _ = s.addKey(layerID: "base", in: large(s, m))
        let edited = try XCTUnwrap(s.largeLayout(computer: c, mode: m))
        var shot: [String: Any]?
        d.observe = { ev in if ev == "before:sidekey.app.v5" { shot = d.dictionaryRepresentation().filter { $0.key.hasPrefix("sidekey.") } } }
        s.resetMode(large(s, m), scope: .both)
        d.observe = nil
        let snap = try XCTUnwrap(shot)                                          // 中间形态已写、主存档还没提交
        let lraw = try XCTUnwrap(snap[LayoutStore.largeStoreKey] as? Data)
        XCTAssertNotNil(LayoutStore.decodeLargeFile(lraw)?.pending, "前提: 这一刻磁盘上是带提交依据的中间形态")
        let rn = name + ".replay"
        let r = UserDefaults(suiteName: rn)!; r.removePersistentDomain(forName: rn)
        for (k, v) in snap { r.set(v, forKey: k) }
        // 旧版 (不认识 sidekey.large.v1) 改写主存档: 改个电脑名后保存
        var p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: try XCTUnwrap(snap["sidekey.app.v5"] as? Data))
        p.computers[0].name = "旧版改的名"
        r.set(try SidekeyJSON.encode(p), forKey: "sidekey.app.v5")
        let back = LayoutStore(defaults: r)
        XCTAssertEqual(back.computer(c)?.name, "旧版改的名")
        XCTAssertEqual(back.largeLayout(computer: c, mode: m), edited, "提交前的大屏编辑保留 (哈希对不上不删除)")
        XCTAssertNil(back.largeRecovery)
    }

    // 历史存档 (1.0、Codex Micro) 的每个模式都在合法范围内, 生成结果写得出、读得回
    func testHistoricalArchivesGenerateWithinBounds() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        for name in ["v1.0-custom-save.json", "v98af158-codexmicro-save.json"] {
            let p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            var entries: [LargeKey: LargeLayout] = [:]
            for c in p.computers { for m in c.modes { if let g = LargeLayoutGenerator.generate(from: m) { entries[LargeKey(computer: c.id, mode: m.id)] = g } } }
            XCTAssertFalse(entries.isEmpty, name)
            XCTAssertNotNil(LayoutStore.encodeLarge(entries).flatMap(LayoutStore.decodeLarge), name)
        }
    }

    // 迁移 / 读写幂等: 读 → 存 → 读多少次结果都一样
    func testLoadSaveIdempotent() {
        let d = defaults("lg-idem")
        let s = LayoutStore(defaults: d)
        for m in s.currentComputer!.modes.map(\.id) { s.ensureLarge(computer: s.currentComputerID, mode: m) }
        let first = largeOnDisk(d)
        for _ in 0..<3 { let r = LayoutStore(defaults: d); _ = r.addPage(); r.deleteLayer(id: r.layers.last!.id) }
        XCTAssertEqual(largeOnDisk(d), first)
    }

    // M2 第三轮 B2: 原键位里有 col = Int.max 的旧数据 → 改列数、加键、复制都不崩; 不安全的操作拒绝并保留原值
    func testLegacyHugeCoordinatesNeverOverflow() {
        let d = defaults("lg-r3-overflow")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s), t = original(s, m)
        s.setLayersForDebug(mode: m, layers: [KeyLayer(id: "base", columns: 4, keys: [
            KeyCap(label: "MaxCol", code: "a", col: Int.max, row: 0),
            KeyCap(label: "MaxRow", code: "b", col: 0, row: Int.max, colSpan: Int.max, rowSpan: Int.max),
        ])])
        XCTAssertNil(s.ensureLarge(computer: c, mode: m))
        s.removeColumn(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 4, "有键会越界: 拒绝缩列, 保留原值")
        s.addColumn(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 5)
        let added = s.addKey(layerID: "base", in: t)
        XCTAssertNotNil(added, "第 1 列 0 行是空的")
        XCTAssertNotNil(s.duplicateKey(layerID: "base", capID: added!, in: t))
        XCTAssertTrue(LayoutStore.regionFree(in: s.layer("base", in: t)!, col: 4, row: 5, colSpan: 1, rowSpan: 1, excluding: nil),
                      "旧键都在极远处 (col / row = Int.max): 不占网格里的格子, 也不溢出")
        XCTAssertNil(LayoutStore(defaults: d).recovery)
    }

    // M2 第三轮 I1: 占用按二维矩形判断, 不同格子不会撞; 找空位覆盖全部合法行 (到 9999)
    func testOccupancyIsTwoDimensionalAndSearchCoversAllRows() {
        let tall = KeyLayer(id: "base", columns: 2, keys: [KeyCap(label: "T", code: "a", col: 0, row: 1000)])
        XCTAssertTrue(LayoutStore.regionFree(in: tall, col: 1, row: 0, colSpan: 1, rowSpan: 1, excluding: nil))
        XCTAssertFalse(LayoutStore.regionFree(in: tall, col: 0, row: 1000, colSpan: 1, rowSpan: 1, excluding: nil))
        let d = defaults("lg-r3-rows")
        let s = LayoutStore(defaults: d)
        let m = vibeID(s), t = original(s, m)
        var keys = (0..<1000).map { KeyCap(label: "K\($0)", code: "a", col: 0, row: $0) }
        keys.append(KeyCap(label: "Bottom", code: "b", col: 0, row: 9999))
        s.setLayersForDebug(mode: m, layers: [KeyLayer(id: "base", columns: 1, keys: keys)])
        let id = s.addKey(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.keys.first { $0.id == id }?.row, 1000)
        // 合法范围全满: 不加 (不追加到范围外)
        s.setLayersForDebug(mode: m, layers: [KeyLayer(id: "base", columns: 1, keys: [KeyCap(label: "Full", code: "a", col: 0, row: 0, rowSpan: 10_000)])])
        XCTAssertNil(s.addKey(layerID: "base", in: t))
        XCTAssertEqual(s.layer("base", in: t)?.keys.count, 1)
        XCTAssertNil(LayoutStore(defaults: d).recovery)
    }

    // M2 第三轮 I2: 列数上限和 LayoutBounds 一致 (256); 超出范围的请求拒绝, 不悄悄夹小
    func testColumnLimitMatchesBounds() {
        let d = defaults("lg-r3-cols")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        s.setLayersForDebug(mode: m, layers: [KeyLayer(id: "base", columns: 20, keys: [KeyCap(label: "A", code: "a")])])
        XCTAssertNotNil(s.ensureLarge(computer: c, mode: m))
        for t in [original(s, m), large(s, m)] {
            s.setColumns(layerID: "base", 21, in: t)
            XCTAssertEqual(s.layer("base", in: t)?.columns, 21)
            s.setColumns(layerID: "base", LayoutBounds.maxColumns, in: t)
            XCTAssertEqual(s.layer("base", in: t)?.columns, 256)
            s.addColumn(layerID: "base", in: t)
            XCTAssertEqual(s.layer("base", in: t)?.columns, 256, "超过上限: 拒绝, 保留原值")
            s.setColumns(layerID: "base", 0, in: t)
            XCTAssertEqual(s.layer("base", in: t)?.columns, 256)
        }
        XCTAssertNil(LayoutStore(defaults: d).largeRecovery)
    }

    // M2 抽查后的调整: 编辑器「+1」最多到 16 列 (1.0 行为); 已超过 16 列的保持不动、按钮不可用; store 上限仍是 256
    func testEditorAddColumnCapsAtSixteenWithoutShrinking() {
        let d = defaults("lg-cols-editor")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        s.setLayersForDebug(mode: m, layers: [KeyLayer(id: "base", columns: 15, keys: [KeyCap(label: "A", code: "a")])])
        let t = original(s, m)
        XCTAssertTrue(s.canAddColumn(layerID: "base", in: t))
        s.addColumn(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 16)
        XCTAssertFalse(s.canAddColumn(layerID: "base", in: t))
        s.addColumn(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 16, "到 16 列就不再加")
        s.setColumns(layerID: "base", 20, in: t)                                     // store 层仍可到 256 (例如大屏键位带过来的 20 列)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 20)
        XCTAssertFalse(s.canAddColumn(layerID: "base", in: t))
        s.addColumn(layerID: "base", in: t)
        XCTAssertEqual(s.layer("base", in: t)?.columns, 20, "超过 16 列: 点 +1 保持不动, 不缩小")
        XCTAssertNotNil(s.ensureLarge(computer: c, mode: m))
        let lt = large(s, m)
        XCTAssertEqual(s.layer("base", in: lt)?.columns, 20)
        s.addColumn(layerID: "base", in: lt)
        XCTAssertEqual(s.layer("base", in: lt)?.columns, 20, "大屏编辑器先沿用 16 的上限")
        XCTAssertEqual(s.largeLayout(computer: c, mode: m)?.edited, false, "被拒绝的 +1 不算编辑")
    }

    // §6.1 第 10 条: 「从原键位重新生成」和重置也按「原键位是否出厂」选
    func testRegenerateAndResetFollowFactoryCondition() {
        let d = defaults("lg-factory-vibe")
        let s = LayoutStore(defaults: d)
        let c = s.currentComputerID, m = vibeID(s)
        XCTAssertEqual(s.ensureLarge(computer: c, mode: m)?.layers[0].keys.count, 18, "出厂 Vibe 第一次在内屏打开")
        var esc = s.layers(in: original(s, m))[0].keys.first { $0.label == "ESC" }!
        esc.label = "退出"
        XCTAssertTrue(s.updateKey(layerID: "base", cap: esc, in: original(s, m)))
        XCTAssertEqual(s.largeLayout(computer: c, mode: m)?.layers[0].keys.count, 18, "已生成的不自动替换 (§6.2)")
        XCTAssertTrue(s.regenerateLarge(computer: c, mode: m))
        XCTAssertEqual(s.largeLayout(computer: c, mode: m)?.layers[0].keys.count, 5, "原键位改过: 照第 1–8 条推导")
        s.resetMode(original(s, m), scope: .both)                     // 原键位恢复出厂, 大屏回到「还没生成」
        XCTAssertNil(s.largeLayout(computer: c, mode: m))
        XCTAssertEqual(s.ensureLarge(computer: c, mode: m)?.layers[0].keys.count, 18)
        XCTAssertNil(LayoutStore(defaults: d).largeRecovery)
    }

    // M3f: 旧存档升级到内置 v12 时按类型标识补上「笔记本键盘」; 用户自建的同名网格模式不算; 已有就不重复补
    func testLaptopBuiltinAddedByKindNotName() throws {
        let d = defaults("lg-laptop-builtin")
        let s = LayoutStore(defaults: d)
        XCTAssertEqual(s.currentComputer!.modes.filter { $0.kind == .laptopKeyboard }.count, 1)
        // 模拟 v11 存档: 去掉笔记本键盘, 加一个用户自建的同名网格模式, 版本号退回 11
        let data = try XCTUnwrap(d.data(forKey: LayoutStore.storeKey))
        var p = try SidekeyJSON.decode(LayoutStore.Persisted.self, from: data)
        p.computers[0].modes.removeAll { $0.kind == .laptopKeyboard }
        p.computers[0].modes.append(Mode(name: "笔记本键盘", layers: DefaultLayout.makeDefault()))
        p.builtinVersion = 11
        d.set(try SidekeyJSON.encode(p), forKey: LayoutStore.storeKey)
        let r = LayoutStore(defaults: d)
        XCTAssertEqual(r.currentComputer!.modes.filter { $0.kind == .laptopKeyboard }.count, 1, "按类型补上")
        XCTAssertEqual(r.currentComputer!.modes.filter { $0.name == "笔记本键盘" && $0.kind == .grid }.count, 1, "自建同名模式保留")
        XCTAssertEqual(LayoutStore(defaults: d).currentComputer!.modes.filter { $0.kind == .laptopKeyboard }.count, 1, "不重复补")
    }
}
