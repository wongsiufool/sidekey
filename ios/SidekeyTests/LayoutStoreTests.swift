import XCTest
@testable import Sidekey

/// 网格布局 (v4) 的逻辑测试: 键的增删改、移动、缩放、列数、分层、清空、持久化、编解码。
@MainActor
final class LayoutStoreTests: XCTestCase {

    private func clearKeys() {
        let d = UserDefaults.standard
        ["sidekey.app.v5", "sidekey.app.v4", "sidekey.app.v3", "sidekey.layout.v2", "sidekey.layout.v1",
         "sidekey.host", "sidekey.port", "sidekey.token"].forEach { d.removeObject(forKey: $0) }
    }

    override func setUp() { super.setUp(); clearKeys() }
    override func tearDown() { clearKeys(); super.tearDown() }

    // 空数据时种入内置默认模式 Vibe (v9 单页触控板), base 是 12 列网格、有键。
    func testSeedsDefaultWhenEmpty() {
        let store = LayoutStore()
        XCTAssertEqual(store.layers.map(\.id), ["base"])
        XCTAssertEqual(store.layer("base")?.columns, 12)
        XCTAssertFalse(store.layer("base")!.keys.isEmpty)
    }

    // 加键: 在第一个空格子放一个 1×1「新键」。
    func testAddKeyPlacesOneInFreeCell() {
        let store = LayoutStore()
        store.clearLayer(id: "base")
        let id = store.addKey(layerID: "base")
        XCTAssertNotNil(id)
        XCTAssertEqual(store.layer("base")!.keys.count, 1)
        let k = store.layer("base")!.keys[0]
        XCTAssertEqual(k.label, "新键")
        XCTAssertEqual(k.colSpan, 1); XCTAssertEqual(k.rowSpan, 1)
        XCTAssertEqual(k.col, 0); XCTAssertEqual(k.row, 0)   // 空层第一个空格
    }

    // 改键: 按 id 定位替换内容, id 与位置不变。
    func testUpdateKeyChangesByID() {
        let store = LayoutStore()
        var cap = store.layer("base")!.keys.first!
        let id = cap.id, col = cap.col
        cap.label = "改过了"; cap.code = "f5"; cap.mods = ["primary"]
        store.updateKey(layerID: "base", cap: cap)
        let updated = store.layer("base")!.keys.first { $0.id == id }!
        XCTAssertEqual(updated.label, "改过了")
        XCTAssertEqual(updated.code, "f5")
        XCTAssertEqual(updated.col, col)                      // 位置没动
    }

    // 删键: 该键消失。
    func testDeleteKeyRemovesIt() {
        let store = LayoutStore()
        let cap = store.layer("base")!.keys.first!
        let before = store.layer("base")!.keys.count
        store.deleteKey(layerID: "base", capID: cap.id)
        XCTAssertEqual(store.layer("base")!.keys.count, before - 1)
        XCTAssertFalse(store.layer("base")!.keys.contains { $0.id == cap.id })
    }

    // 移动: 移到空格成功; 移到被占格 / 越界失败。
    func testMoveKeyFreeVsOccupied() {
        let store = LayoutStore()
        store.clearLayer(id: "base")
        let a = store.addKey(layerID: "base")!          // (0,0)
        let b = store.addKey(layerID: "base")!          // (1,0)
        XCTAssertTrue(store.moveKey(layerID: "base", capID: a, toCol: 5, toRow: 5))
        let ka = store.layer("base")!.keys.first { $0.id == a }!
        XCTAssertEqual(ka.col, 5); XCTAssertEqual(ka.row, 5)
        XCTAssertFalse(store.moveKey(layerID: "base", capID: b, toCol: 5, toRow: 5))   // 被 a 占
        XCTAssertFalse(store.moveKey(layerID: "base", capID: b, toCol: 99, toRow: 0))  // 越界
    }

    // 缩放: 空地加宽加高成功; 撑到别人 / 越出列数失败。
    func testResizeKeyFreeVsOverlapVsBounds() {
        let store = LayoutStore()
        store.clearLayer(id: "base")
        let a = store.addKey(layerID: "base")!          // (0,0)
        XCTAssertTrue(store.resizeKey(layerID: "base", capID: a, colSpan: 2, rowSpan: 2))
        XCTAssertEqual(store.layer("base")!.keys.first!.colSpan, 2)
        let b = store.addKey(layerID: "base")!          // a 占 (0..1,0..1), 第一个空格 = (2,0)
        _ = b
        XCTAssertFalse(store.resizeKey(layerID: "base", capID: a, colSpan: 3, rowSpan: 2))  // 会撞到 b
        XCTAssertFalse(store.resizeKey(layerID: "base", capID: a, colSpan: 9, rowSpan: 1))  // 越出 8 列
    }

    // 列数: 加减列; 缩到会切到键时被拒。
    func testColumnsAddRemoveAndClampGuard() {
        let store = LayoutStore()
        XCTAssertEqual(store.layer("base")!.columns, 12)
        store.addColumn(layerID: "base")
        XCTAssertEqual(store.layer("base")!.columns, 13)
        store.removeColumn(layerID: "base")
        XCTAssertEqual(store.layer("base")!.columns, 12)
        store.setColumns(layerID: "base", 7)               // 回退/确认 占满 12 列, 缩到 7 会切掉
        XCTAssertEqual(store.layer("base")!.columns, 12)   // 被拒, 不变
    }

    // 加页 / 删页; 新页是空的 (靠滑动切换, 不放切层键)。
    func testAddAndDeleteLayer() {
        let store = LayoutStore()
        store.addLayer(named: "nav")
        XCTAssertNotNil(store.layer("nav"))
        XCTAssertTrue(store.layer("nav")!.keys.isEmpty)
        store.deleteLayer(id: "nav")
        XCTAssertNil(store.layer("nav"))
    }

    // 页排序: 交换相邻页顺序; 越界不动。
    func testMovePageReorders() {
        let store = LayoutStore()
        store.addLayer(named: "more")                          // Vibe 现单页, 先加一页
        XCTAssertEqual(store.layers.map(\.id), ["base", "more"])
        XCTAssertTrue(store.movePage(id: "base", by: 1))       // base 右移 → [more, base]
        XCTAssertEqual(store.layers.map(\.id), ["more", "base"])
        XCTAssertFalse(store.movePage(id: "more", by: -1))     // 已在最左, 越界不动
        XCTAssertEqual(store.layers.map(\.id), ["more", "base"])
    }

    // base 层不可删。
    func testCannotDeleteBaseLayer() {
        let store = LayoutStore()
        store.deleteLayer(id: "base")
        XCTAssertNotNil(store.layer("base"))
    }

    // 清空本层: 键全没了, 层还在; 其它层不受影响。
    func testClearLayerRemovesAllKeysButKeepsLayer() {
        let store = LayoutStore()
        store.addLayer(named: "more")            // Vibe 现单页, 加一页作「其它层」
        store.addKey(layerID: "more")           // 给它放一个键
        XCTAssertFalse(store.layer("base")!.keys.isEmpty)
        let moreCount = store.layer("more")!.keys.count
        store.clearLayer(id: "base")
        XCTAssertNotNil(store.layer("base"))
        XCTAssertTrue(store.layer("base")!.keys.isEmpty)
        XCTAssertEqual(store.layer("more")!.keys.count, moreCount)
    }

    // 清空后仍可用「加键」从零搭回来。
    func testCanRebuildAfterClear() {
        let store = LayoutStore()
        store.clearLayer(id: "base")
        store.addKey(layerID: "base")
        store.addKey(layerID: "base")
        XCTAssertEqual(store.layer("base")!.keys.count, 2)
    }

    // 清空只动当前模式: 另一个模式的同名层不受影响。
    func testClearLayerScopedToCurrentMode() {
        let store = LayoutStore()
        let other = store.addMode(named: "工作")!
        store.clearLayer(id: "base")
        XCTAssertTrue(store.layer("base")!.keys.isEmpty)
        store.selectMode(other)
        XCTAssertFalse(store.layer("base")!.keys.isEmpty)
    }

    // 重置回默认。
    func testResetToDefault() {
        let store = LayoutStore()
        store.addLayer(named: "extra")
        store.resetToDefault()
        XCTAssertEqual(store.layers.map(\.id), ["base", "more"])
        XCTAssertNil(store.layer("extra"))
    }

    // 跨实例持久化 (改动写入 UserDefaults, 新实例读得到)。
    func testPersistenceAcrossInstances() {
        let store1 = LayoutStore()
        var cap = store1.layer("base")!.keys.first!
        cap.label = "持久化测试"
        store1.updateKey(layerID: "base", cap: cap)
        store1.addLayer(named: "extra")

        let store2 = LayoutStore()
        XCTAssertEqual(store2.layer("base")!.keys.first!.label, "持久化测试")
        XCTAssertNotNil(store2.layer("extra"))
    }

    // 复制键: 内容相同、id 全新、放到别处(不和源重叠)。
    func testDuplicateKey() {
        let store = LayoutStore()
        store.clearLayer(id: "base")
        let a = store.addKey(layerID: "base")!
        var cap = store.layer("base")!.keys.first!
        cap.label = "源"; cap.code = "f9"
        store.updateKey(layerID: "base", cap: cap)
        let copyID = store.duplicateKey(layerID: "base", capID: a)!
        XCTAssertEqual(store.layer("base")!.keys.count, 2)
        let copy = store.layer("base")!.keys.first { $0.id == copyID }!
        XCTAssertNotEqual(copy.id, a)
        XCTAssertEqual(copy.label, "源")
        XCTAssertEqual(copy.code, "f9")
        XCTAssertFalse(copy.col == 0 && copy.row == 0)
    }

    // 网格布局 Codable 编解码无损 (含 columns / col / span)。
    func testCodableRoundTrip() throws {
        let layers = DefaultLayout.makeDefault()
        let data = try JSONEncoder().encode(layers)
        let decoded = try JSONDecoder().decode([KeyLayer].self, from: data)
        XCTAssertEqual(decoded.map(\.id), layers.map(\.id))
        XCTAssertEqual(decoded[0].columns, layers[0].columns)
        XCTAssertEqual(decoded[0].keys[0].code, layers[0].keys[0].code)
        XCTAssertEqual(decoded[0].keys[0].col, layers[0].keys[0].col)
        XCTAssertEqual(decoded[0].keys[0].id, layers[0].keys[0].id)
    }
}
