import XCTest
@testable import Sidekey

/// 电脑 / 模式 模型 + v3→v4 迁移 + v4 持久化。
/// 用独立的 UserDefaults suite, 每个用例互不干扰 (不碰 .standard)。
@MainActor
final class ComputerStoreTests: XCTestCase {

    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "test.computerstore.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// 写一份 v3 老存档 (行流式布局)。`layers` 字段会被 v4 迁移忽略 (布局重置)。
    private func seedV3(_ d: UserDefaults, computerID cid: String, modeID mid: String,
                        name: String = "台式机", host: String = "192.168.1.50",
                        port: Int = 9000, token: String = "tok-abc", modeName: String = "工作") {
        let json = """
        {"computers":[{"id":"\(cid)","name":"\(name)","host":"\(host)","port":\(port),\
        "token":"\(token)","modes":[{"id":"\(mid)","name":"\(modeName)","layers":\
        [{"id":"base","rows":[[{"id":"33333333-3333-3333-3333-333333333333","label":"老键",\
        "code":"f7","mods":[],"width":1,"kind":"normal"}]]}]}],"lastModeID":"\(mid)"}],\
        "currentComputerID":"\(cid)","currentModeID":"\(mid)"}
        """
        d.set(Data(json.utf8), forKey: "sidekey.app.v3")
    }

    // 全新安装: 一台电脑 · 两个内置模式 (Vibe Coding 默认 + vibecoding键盘模式); Vibe 单页(触控板)。
    func testFreshInstallSeedsBuiltinModes() {
        let store = LayoutStore(defaults: freshDefaults())
        XCTAssertEqual(store.computers.count, 1)
        XCTAssertEqual(store.currentComputer?.id, store.currentComputerID)
        XCTAssertEqual(store.currentComputer?.modes.count, 2)
        XCTAssertEqual(store.currentComputer?.modes.map(\.name), ["Vibe Coding", "vibecoding键盘模式"])
        XCTAssertEqual(store.currentMode?.name, "Vibe Coding")        // 默认选中 Vibe
        XCTAssertEqual(store.currentMode?.id, store.currentModeID)
        XCTAssertEqual(store.layers.map(\.id), ["base"])              // Vibe 现单页
    }

    // 没有任何老数据: 端口缺省 8765, 名字「我的电脑」。
    func testFreshInstallUsesDefaults() {
        let store = LayoutStore(defaults: freshDefaults())
        XCTAssertEqual(store.currentComputer?.name, "我的电脑")
        XCTAssertEqual(store.currentComputer?.port, 8765)
        XCTAssertEqual(store.currentComputer?.host, "")
    }

    // v3→v4 迁移: 电脑/连接/模式 名称与 id 全部保留, 但布局重置成网格默认 (用户选「全新默认」)。
    func testMigratesV3PreservesComputerResetsLayout() {
        let d = freshDefaults()
        let cid = "11111111-1111-1111-1111-111111111111"
        let mid = "22222222-2222-2222-2222-222222222222"
        seedV3(d, computerID: cid, modeID: mid)

        let store = LayoutStore(defaults: d)
        XCTAssertEqual(store.computers.count, 1)
        XCTAssertEqual(store.currentComputer?.name, "台式机")
        XCTAssertEqual(store.currentComputer?.host, "192.168.1.50")
        XCTAssertEqual(store.currentComputer?.port, 9000)
        XCTAssertEqual(store.currentComputer?.token, "tok-abc")
        XCTAssertEqual(store.currentMode?.name, "工作")
        XCTAssertEqual(store.currentComputerID, UUID(uuidString: cid))
        XCTAssertEqual(store.currentModeID, UUID(uuidString: mid))
        // 布局被重置成网格默认 (base + more), 老键没了
        XCTAssertEqual(store.layers.map(\.id), ["base", "more"])
        XCTAssertEqual(store.layer("base")?.columns, 8)
        XCTAssertFalse(store.layer("base")!.keys.isEmpty)
        XCTAssertFalse(store.layer("base")!.keys.contains { $0.label == "老键" })
    }

    // v4 持久化: 改当前模式的键 -> 同 defaults 的新实例读得到。
    func testPersistsV4AcrossInstances() {
        let d = freshDefaults()
        let s1 = LayoutStore(defaults: d)
        var cap = s1.layer("base")!.keys.first!
        cap.label = "改了"
        s1.updateKey(layerID: "base", cap: cap)

        let s2 = LayoutStore(defaults: d)
        XCTAssertEqual(s2.layer("base")?.keys.first?.label, "改了")
        XCTAssertEqual(s2.computers.count, 1)
    }

    // 迁移只发生一次: 第二次启动读 v4 (含改动), 不再回头迁移 v3。
    func testV4WinsOverV3OnSecondLaunch() {
        let d = freshDefaults()
        seedV3(d, computerID: "44444444-4444-4444-4444-444444444444",
               modeID: "55555555-5555-5555-5555-555555555555")
        let s1 = LayoutStore(defaults: d)               // 迁移 + 写 v4
        s1.addLayer(named: "nav")                        // 在 v4 上改
        let s2 = LayoutStore(defaults: d)               // 应读 v4 (含 nav)
        XCTAssertNotNil(s2.layer("nav"))
    }

    // 选择模式: currentModeID + 该电脑 lastModeID 一起更新并持久化。
    func testSelectModePersists() {
        let d = freshDefaults()
        let s1 = LayoutStore(defaults: d)
        let modeID = s1.currentModeID
        s1.selectMode(modeID)
        XCTAssertEqual(s1.currentComputer?.lastModeID, modeID)

        let s2 = LayoutStore(defaults: d)
        XCTAssertEqual(s2.currentComputer?.lastModeID, modeID)
    }

    // 编辑当前模式不会改到模型外: computers 始终只有一台。
    func testEditingDoesNotSpawnExtraComputers() {
        let store = LayoutStore(defaults: freshDefaults())
        store.addLayer(named: "nav")
        store.addKey(layerID: "base")
        XCTAssertEqual(store.computers.count, 1)
        XCTAssertEqual(store.currentComputer?.modes.count, 2)   // 内置两模式不变
    }

    // MARK: - 多电脑

    func testAddComputer() {
        let store = LayoutStore(defaults: freshDefaults())
        store.addComputer(Computer.make(name: "笔记本", host: "10.0.0.2", port: 8765, token: "t"))
        XCTAssertEqual(store.computers.count, 2)
        XCTAssertTrue(store.computers.contains { $0.name == "笔记本" })
    }

    func testUpsertFillsEmptyDefaultComputer() {
        let store = LayoutStore(defaults: freshDefaults())
        XCTAssertEqual(store.currentComputer?.host, "")
        let id = store.upsertComputer(name: "台式机", host: "192.168.1.9", port: 9000, token: "tok")
        XCTAssertEqual(store.computers.count, 1)
        XCTAssertEqual(id, store.currentComputerID)
        XCTAssertEqual(store.currentComputer?.host, "192.168.1.9")
        XCTAssertEqual(store.currentComputer?.port, 9000)
        XCTAssertEqual(store.currentComputer?.name, "台式机")
    }

    func testUpsertAddsNewAndUpdatesExisting() {
        let store = LayoutStore(defaults: freshDefaults())
        _ = store.upsertComputer(name: "A", host: "1.1.1.1", port: 8765, token: "ta")
        _ = store.upsertComputer(name: "B", host: "2.2.2.2", port: 8765, token: "tb")
        XCTAssertEqual(store.computers.count, 2)
        _ = store.upsertComputer(name: "A2", host: "1.1.1.1", port: 8800, token: "ta2")
        XCTAssertEqual(store.computers.count, 2)
        let a = store.computers.first { $0.host == "1.1.1.1" }
        XCTAssertEqual(a?.token, "ta2")
        XCTAssertEqual(a?.port, 8800)
    }

    func testRenameComputer() {
        let store = LayoutStore(defaults: freshDefaults())
        let id = store.currentComputerID
        store.renameComputer(id: id, to: "  办公台式机 ")
        XCTAssertEqual(store.currentComputer?.name, "办公台式机")
        store.renameComputer(id: id, to: "   ")
        XCTAssertEqual(store.currentComputer?.name, "办公台式机")
    }

    func testDeleteCurrentSwitchesToAnother() {
        let store = LayoutStore(defaults: freshDefaults())
        let first = store.currentComputerID
        store.addComputer(Computer.make(name: "第二台", host: "3.3.3.3"))
        store.deleteComputer(id: first)
        XCTAssertEqual(store.computers.count, 1)
        XCTAssertNotEqual(store.currentComputerID, first)
        XCTAssertEqual(store.currentComputer?.name, "第二台")
        XCTAssertEqual(store.currentMode?.id, store.currentModeID)
    }

    func testCannotDeleteLastComputer() {
        let store = LayoutStore(defaults: freshDefaults())
        store.deleteComputer(id: store.currentComputerID)
        XCTAssertEqual(store.computers.count, 1)
    }

    // MARK: - 模式

    func testAddMode() {
        let store = LayoutStore(defaults: freshDefaults())
        let id = store.addMode(named: "工作")
        XCTAssertNotNil(id)
        XCTAssertEqual(store.currentComputer?.modes.count, 3)   // 内置 2 + 新增 1
        XCTAssertTrue(store.currentComputer?.modes.contains { $0.name == "工作" } ?? false)
    }

    func testRenameMode() {
        let store = LayoutStore(defaults: freshDefaults())
        store.renameMode(id: store.currentModeID, to: " Sidekey娱乐 ")
        XCTAssertEqual(store.currentMode?.name, "Sidekey娱乐")
    }

    func testDeleteModeSwitchesCurrent() {
        let store = LayoutStore(defaults: freshDefaults())
        let first = store.currentModeID
        let second = store.addMode(named: "工作")!
        store.selectMode(second)
        store.deleteMode(id: second)
        XCTAssertEqual(store.currentComputer?.modes.count, 2)   // 删回内置两模式
        XCTAssertEqual(store.currentModeID, first)
    }

    func testCannotDeleteLastMode() {
        let store = LayoutStore(defaults: freshDefaults())
        // 内置 2 个 -> 删一个到只剩 1 个
        store.deleteMode(id: store.currentModeID)
        XCTAssertEqual(store.currentComputer?.modes.count, 1)
        store.deleteMode(id: store.currentModeID)   // 最后一个不可删
        XCTAssertEqual(store.currentComputer?.modes.count, 1)
    }

    // 复制模式: 新模式 id 与每个键 id 都是全新的, 但内容一致。
    func testDuplicateModeHasFreshIDs() {
        let store = LayoutStore(defaults: freshDefaults())
        let srcID = store.currentModeID
        let srcCapID = store.layers[0].keys[0].id
        let copyID = store.duplicateMode(id: srcID)!
        XCTAssertNotEqual(copyID, srcID)
        XCTAssertEqual(store.currentComputer?.modes.count, 3)      // 内置 2 + 副本 1
        let copy = store.currentComputer!.modes.first { $0.id == copyID }!
        XCTAssertTrue(copy.name.hasSuffix("副本"))
        XCTAssertEqual(copy.layers.map(\.id), ["base"])            // Vibe 现单页
        XCTAssertNotEqual(copy.layers[0].keys[0].id, srcCapID)     // 键 id 换新
        XCTAssertEqual(copy.layers[0].keys[0].label, "触控板")      // 内容一致 (新 Vibe 首键 = 触控板)
    }

    func testDuplicateModeToOtherComputer() {
        let store = LayoutStore(defaults: freshDefaults())
        store.addComputer(Computer.make(name: "第二台", host: "9.9.9.9"))
        let other = store.computers.first { $0.name == "第二台" }!
        let before = other.modes.count
        store.duplicateMode(id: store.currentModeID, toComputer: other.id)
        let after = store.computers.first { $0.id == other.id }!
        XCTAssertEqual(after.modes.count, before + 1)
    }

    // 核心: 改 A 模式的键, 不影响 B 模式 (每模式各自独立)。
    func testEditingOneModeDoesNotAffectAnother() {
        let store = LayoutStore(defaults: freshDefaults())
        let a = store.currentModeID
        let b = store.addMode(named: "B")!
        store.selectMode(a)
        var cap = store.layer("base")!.keys.first!
        cap.label = "A专属"
        store.updateKey(layerID: "base", cap: cap)
        store.selectMode(b)
        XCTAssertNotEqual(store.layer("base")?.keys.first?.label, "A专属")
        store.selectMode(a)
        XCTAssertEqual(store.layer("base")?.keys.first?.label, "A专属")
    }

    // 审计【阻断】#1: 非破坏补内置 —— 用户编辑/自建模式都保住, 缺的内置才补, 不重复加。
    func testAddMissingBuiltinsPreservesUserData() {
        let store = LayoutStore(defaults: freshDefaults())
        var cap = store.layer("base")!.keys.first!
        cap.label = "我的键"
        store.updateKey(layerID: "base", cap: cap)
        let custom = store.addMode(named: "我的模式")!
        let before = Set(store.currentComputer!.modes.map(\.name))
        store.addMissingBuiltins()
        XCTAssertEqual(store.layer("base")?.keys.first?.label, "我的键")           // 编辑没丢
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.id == custom })  // 自建模式还在
        XCTAssertEqual(Set(store.currentComputer!.modes.map(\.name)), before)     // 没重复加内置
    }

    // MARK: - 内置布局升级 (v3 → v4: 新版 Vibe Coding 3×3 / 4×4 + 权限模式键)

    private func oldV3VibeBaseLabels() -> [String] {
        ["复制", "粘贴", "撤销", "重做", "命令面板", "侧栏", "注释", "运行", "语音输入", "左", "下", "右"]
    }
    private func oldV3VibeMoreLabels() -> [String] {
        ["上", "左", "下", "右", "Home", "End", "PgUp", "PgDn", "Esc", "主键盘"]
    }
    private func makeOldV3Vibe(id: UUID, baseLabels: [String]? = nil) -> Mode {
        let base = (baseLabels ?? oldV3VibeBaseLabels()).enumerated().map {
            KeyCap(label: $0.element, code: "x", col: ($0.offset % 3) * 4, row: $0.offset / 3, colSpan: 4)
        }
        let more = oldV3VibeMoreLabels().enumerated().map {
            KeyCap(label: $0.element, code: "x", col: 0, row: $0.offset, colSpan: 4)
        }
        return Mode(id: id, name: "Vibe Coding",
                    layers: [KeyLayer(id: "base", columns: 12, keys: base),
                             KeyLayer(id: "more", columns: 12, keys: more)])
    }
    /// 把一份「v3 版本号」的存档写进 v5 storeKey (布局升级靠 builtinVersion 触发, 与 key 名无关)。
    private func seedPersisted(_ d: UserDefaults, computers: [Computer],
                               current: UUID, mode: UUID, builtinVersion: Int?) {
        struct P: Codable {
            var computers: [Computer]; var currentComputerID: UUID
            var currentModeID: UUID; var builtinVersion: Int?
        }
        let p = P(computers: computers, currentComputerID: current, currentModeID: mode, builtinVersion: builtinVersion)
        d.set(try! JSONEncoder().encode(p), forKey: "sidekey.app.v5")
    }

    // 验收: 未编辑的旧 (v3) Vibe Coding 安全升级到新版; 电脑连接信息保留。
    func testUpgradesUneditedV3VibeLayout() {
        let d = freshDefaults()
        let cid = UUID(), vibeID = UUID(), workID = UUID()
        let work = Mode(id: workID, name: "工作模式",
                        layers: [KeyLayer(id: "base", columns: 12,
                                          keys: [KeyCap(label: "复制", code: "c", mods: ["primary"], col: 0, row: 0, colSpan: 4)])])
        let comp = Computer(id: cid, name: "台式机", host: "1.2.3.4", port: 8765, token: "tok",
                            fingerprint: "", modes: [makeOldV3Vibe(id: vibeID), work], lastModeID: vibeID)
        seedPersisted(d, computers: [comp], current: cid, mode: vibeID, builtinVersion: 3)

        let store = LayoutStore(defaults: d)
        let vibe = store.currentComputer?.modes.first { $0.name == "Vibe Coding" }
        // 升级到最新出厂 Vibe (v9 单页, 用户固化布局): 触控板 + 左键/SPACE/Backspace + Typeless/ENTER/ESC
        XCTAssertEqual(vibe?.layers.first { $0.id == "base" }?.keys.map(\.label),
                       ["触控板", "左键", "SPACE", "Backspace", "Typeless", "ENTER", "ESC"])
        // v9: Vibe 升级后为单页, 不再有第二页
        XCTAssertEqual(vibe?.layers.map(\.id), ["base"])
        // 首页含一块触控板 (新出厂布局)
        XCTAssertTrue(vibe?.layers.first { $0.id == "base" }?.keys.contains { $0.kind == .trackpad } ?? false)
        // 电脑/连接保留
        XCTAssertEqual(store.currentComputer?.host, "1.2.3.4")
        XCTAssertEqual(store.currentComputer?.token, "tok")
    }

    // 验收: 编辑过的同名 Vibe Coding 不被升级覆盖 (任意一处不同即视为已编辑)。
    func testDoesNotUpgradeEditedVibeLayout() {
        let d = freshDefaults()
        let cid = UUID(), vibeID = UUID()
        var labels = oldV3VibeBaseLabels()
        labels[0] = "我改了"
        let comp = Computer(id: cid, name: "C", host: "", port: 8765, token: "",
                            fingerprint: "", modes: [makeOldV3Vibe(id: vibeID, baseLabels: labels)], lastModeID: vibeID)
        seedPersisted(d, computers: [comp], current: cid, mode: vibeID, builtinVersion: 3)

        let store = LayoutStore(defaults: d)
        let base = store.currentComputer?.modes.first { $0.name == "Vibe Coding" }?.layers.first { $0.id == "base" }
        XCTAssertEqual(base?.keys.first?.label, "我改了")                       // 编辑保留
        XCTAssertFalse(base?.keys.contains { $0.kind == .permission } ?? true)  // 没被换成新版
    }

    // 只补「缺的」: 删掉某内置 → addMissingBuiltins 把它补回来。
    func testAddMissingBuiltinsReAddsDeletedBuiltin() {
        let store = LayoutStore(defaults: freshDefaults())
        guard let kbd = store.currentComputer!.modes.first(where: { $0.name == "vibecoding键盘模式" }) else {
            return XCTFail("内置应含「vibecoding键盘模式」")
        }
        store.deleteMode(id: kbd.id)
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "vibecoding键盘模式" })
        store.addMissingBuiltins()
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.name == "vibecoding键盘模式" })
    }

    // MARK: - 触控板编辑 (鼠标模式 v10 已移除)

    // v10: 鼠标模式不再是内置 → 新装不含它。
    func testFreshInstallHasNoMouseMode() {
        let store = LayoutStore(defaults: freshDefaults())
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "鼠标模式" })
    }

    // 加鼠标键: addMouseButton 放一个 .mouseButton(code 对应 left/right)。
    func testAddMouseButton() {
        let store = LayoutStore(defaults: freshDefaults())   // 当前 Vibe base
        let id = store.addMouseButton(layerID: "base", code: "right")
        XCTAssertNotNil(id)
        let added = store.layer("base")?.keys.first { $0.id == id }
        XCTAssertEqual(added?.kind, .mouseButton)
        XCTAssertEqual(added?.code, "right")
    }

    // v10: 已发布的「鼠标模式」(含旧 v7 单块触控板) 升级时被统一删除; 当前选中若指向它则自动改指存活模式。
    func testV10DeletesMouseModeOnUpgrade() {
        let d = freshDefaults()
        let cid = UUID(), mouseID = UUID(), vibeID = UUID()
        let v7mouse = Mode(id: mouseID, name: "鼠标模式", layers: [
            KeyLayer(id: "base", columns: 12, keys: [
                KeyCap(label: "触控板", col: 0, row: 0, colSpan: 12, rowSpan: 6, kind: .trackpad)])])
        let vibe = Mode(id: vibeID, name: "Vibe Coding", layers: BuiltinModes.vibe().layers)
        let comp = Computer(id: cid, name: "C", host: "", port: 8765, token: "",
                            fingerprint: "", modes: [vibe, v7mouse], lastModeID: mouseID)
        seedPersisted(d, computers: [comp], current: cid, mode: mouseID, builtinVersion: 7)

        let store = LayoutStore(defaults: d)
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "鼠标模式" })           // v10 删除
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.id == store.currentModeID })    // 当前模式已改指存活模式
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.name == "vibecoding键盘模式" })  // 新键盘补齐
    }

    // addTrackpad: 一页只放一个 —— 第二次调用被拒。
    func testAddTrackpadOnceThenRejectsSecond() {
        let store = LayoutStore(defaults: freshDefaults())   // 当前 Vibe 单页(base 自带触控板); 加一页用于测试
        store.addLayer(named: "more")
        XCTAssertNil(store.addTrackpad(layerID: "base"))     // base 出厂已有触控板 → 直接拒绝
        let id1 = store.addTrackpad(layerID: "more")
        XCTAssertNotNil(id1)
        XCTAssertEqual(store.layer("more")?.keys.filter { $0.kind == .trackpad }.count, 1)
        let id2 = store.addTrackpad(layerID: "more")
        XCTAssertNil(id2)   // 已有触控板 → 拒绝
        XCTAssertEqual(store.layer("more")?.keys.filter { $0.kind == .trackpad }.count, 1)
    }

    // v10: 未编辑的旧出厂「工作模式」会先被旧迁移改名为「鼠标模式」, 再被 v10 统一删除 → 两个名字都不在。
    func testV10RemovesUneditedFactoryWork() {
        let d = freshDefaults()
        let cid = UUID(), workID = UUID(), vibeID = UUID()
        // 用历史出厂办公 base 单页模拟旧工作模式
        let work = Mode(id: workID, name: "工作模式", layers: [BuiltinModes.legacyWorkBase()])
        let vibe = Mode(id: vibeID, name: "Vibe Coding", layers: BuiltinModes.vibe().layers)
        let comp = Computer(id: cid, name: "C", host: "", port: 8765, token: "",
                            fingerprint: "", modes: [vibe, work], lastModeID: vibeID)
        seedPersisted(d, computers: [comp], current: cid, mode: vibeID, builtinVersion: 6)

        let store = LayoutStore(defaults: d)
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "工作模式" })   // 已改名→鼠标
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "鼠标模式" })   // 再被 v10 删除
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.name == "Vibe Coding" })
    }

    // v10: 编辑过的「工作模式」(改了某键 code) 不被改名/删除(已属自建保留); 内置只补 vibecoding键盘模式, 不含鼠标。
    func testEditedWorkSurvivesAndNoMouseAdded() {
        let d = freshDefaults()
        let cid = UUID(), workID = UUID()
        var base = BuiltinModes.legacyWorkBase()
        base.keys[0].code = "x"   // 改一个键的 code = 编辑过 (标签不变)
        let work = Mode(id: workID, name: "工作模式", layers: [base])
        let comp = Computer(id: cid, name: "C", host: "", port: 8765, token: "",
                            fingerprint: "", modes: [work], lastModeID: workID)
        seedPersisted(d, computers: [comp], current: cid, mode: workID, builtinVersion: 6)

        let store = LayoutStore(defaults: d)
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.name == "工作模式" })        // 编辑过 → 保留
        XCTAssertFalse(store.currentComputer!.modes.contains { $0.name == "鼠标模式" })       // v10 不再内置鼠标
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.name == "vibecoding键盘模式" }) // 补齐新键盘
    }

    // v10 强制统一(综合): 即使编辑过 —— Vibe 收成单页(保留第一页编辑) / 删除鼠标模式 / 自建模式保留 / 新键盘补齐 / 连接保留。
    func testV10ForcesVibeSingleDeletesMouseKeepsCustom() {
        let d = freshDefaults()
        let cid = UUID(), vibeID = UUID(), mouseID = UUID(), customID = UUID()
        var vibeBase = BuiltinModes.vibe().layers[0]
        vibeBase.keys[0].label = "我改的触控板"               // 编辑第一页
        let vibe = Mode(id: vibeID, name: "Vibe Coding", layers: [
            vibeBase,
            KeyLayer(id: "more", columns: 12, keys: [KeyCap(label: "页2键", code: "a", col: 0, row: 0)]),
        ])
        let mouse = Mode(id: mouseID, name: "鼠标模式", layers: [
            KeyLayer(id: "base", columns: 12, keys: [KeyCap(label: "我的鼠标键", code: "left", col: 0, row: 0, kind: .mouseButton)]),
        ])
        let custom = Mode(id: customID, name: "我的自建", layers: DefaultLayout.makeDefault())
        let comp = Computer(id: cid, name: "C", host: "1.2.3.4", port: 8765, token: "tok",
                            fingerprint: "", modes: [vibe, mouse, custom], lastModeID: mouseID)
        seedPersisted(d, computers: [comp], current: cid, mode: mouseID, builtinVersion: 8)

        let store = LayoutStore(defaults: d)
        let names = store.currentComputer!.modes.map(\.name)
        XCTAssertFalse(names.contains("鼠标模式"))                                  // 鼠标删除(即便编辑过)
        let v = store.currentComputer!.modes.first { $0.name == "Vibe Coding" }
        XCTAssertEqual(v?.layers.map(\.id), ["base"])                              // Vibe 收成单页
        XCTAssertEqual(v?.layers.first?.keys.first?.label, "我改的触控板")          // 第一页编辑保留
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.id == customID }) // 自建保留
        XCTAssertTrue(names.contains("vibecoding键盘模式"))                         // 新键盘补齐
        XCTAssertEqual(store.currentComputer?.token, "tok")                        // 连接保留
        XCTAssertTrue(store.currentComputer!.modes.contains { $0.id == store.currentModeID })  // 当前模式已改指存活模式
    }

    // MARK: - 令牌存 Keychain (安全硬化)

    /// 探测当前测试宿主能否用 Keychain; 不能就跳过(CI/无 entitlement), 真机仍生效。
    private func requireKeychain() throws {
        let probe = "probe-\(UUID().uuidString)"
        guard KeychainToken.set("x", for: probe) else { throw XCTSkip("Keychain 在当前测试环境不可用") }
        KeychainToken.delete(probe)
    }

    func testKeychainTokenRoundTrip() throws {
        try requireKeychain()
        let acc = "test-\(UUID().uuidString)"
        XCTAssertNil(KeychainToken.get(acc))
        XCTAssertTrue(KeychainToken.set("hello", for: acc))
        XCTAssertEqual(KeychainToken.get(acc), "hello")
        XCTAssertTrue(KeychainToken.set("world", for: acc))     // 覆盖式写
        XCTAssertEqual(KeychainToken.get(acc), "world")
        XCTAssertTrue(KeychainToken.delete(acc))
        XCTAssertNil(KeychainToken.get(acc))
    }

    /// persist 后: 令牌不再以明文留在 blob; 重新加载仍能从 Keychain 取回。
    func testTokenStoredInKeychainNotPlaintextBlob() throws {
        try requireKeychain()
        let d = freshDefaults()
        let store = LayoutStore(defaults: d)
        let secret = "secret-\(UUID().uuidString)"
        let id = store.upsertComputer(name: "T", host: "10.9.8.7", port: 8765, token: secret)
        defer { KeychainToken.delete(id.uuidString) }

        // blob 里不应再有明文令牌
        let blob = d.data(forKey: "sidekey.app.v5")
        XCTAssertNotNil(blob)
        let json = String(data: blob!, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(secret), "令牌不应再以明文存在 blob 里")

        // 新建一个 store 读同一份 defaults, 仍能恢复令牌(来自 Keychain)
        let store2 = LayoutStore(defaults: d)
        XCTAssertEqual(store2.computers.first { $0.id == id }?.token, secret)
    }

    /// 删电脑要顺带清掉它在 Keychain 里的令牌。(需 ≥2 台, deleteComputer 拒删最后一台)
    func testDeleteComputerClearsKeychainToken() throws {
        try requireKeychain()
        let d = freshDefaults()
        let store = LayoutStore(defaults: d)          // 默认 1 台
        let secret = "secret-\(UUID().uuidString)"
        let c = Computer.make(name: "Gone", host: "10.0.0.9", token: secret)
        store.addComputer(c)                          // 现在 2 台, persist 把令牌写进 Keychain
        XCTAssertEqual(KeychainToken.get(c.id.uuidString), secret)
        store.deleteComputer(id: c.id)
        XCTAssertNil(KeychainToken.get(c.id.uuidString))   // 已清掉
    }

    // MARK: - TLS TOFU

    /// learnFingerprint 只在「当前还没指纹」时固定, 不覆盖已知指纹, 也不接受空值。
    func testLearnFingerprintOnlyWhenEmpty() {
        let d = freshDefaults()
        let store = LayoutStore(defaults: d)
        let c = Computer.make(name: "M", host: "1.1.1.1", token: "t")   // fingerprint 默认空
        store.addComputer(c)
        store.learnFingerprint("aabb", for: c.id)
        XCTAssertEqual(store.computers.first { $0.id == c.id }?.fingerprint, "aabb")  // 学到并固定
        store.learnFingerprint("ccdd", for: c.id)
        XCTAssertEqual(store.computers.first { $0.id == c.id }?.fingerprint, "aabb")  // 已有→不覆盖(防被新证书顶替)
        store.learnFingerprint("", for: c.id)
        XCTAssertEqual(store.computers.first { $0.id == c.id }?.fingerprint, "aabb")  // 空值忽略
    }
}
