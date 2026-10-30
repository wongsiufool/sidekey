import XCTest
@testable import Sidekey

/// 窗口恢复规则 (§4.7, T-MW-8 的纯逻辑部分): 电脑不在了 → 最近使用的电脑; 模式不在了 → 这台电脑的第一个模式; 页不在了 → 第 1 页。
final class WindowStateTests: XCTestCase {
    private func computer(_ modes: [Mode], last: Mode? = nil) -> Computer {
        Computer(name: "C", modes: modes, lastModeID: last?.id)
    }
    private func mode(_ pages: [String]) -> Mode {
        Mode(name: "M", layers: pages.map { KeyLayer(id: $0, columns: 4, keys: []) })
    }

    func testKeepsValidTargets() {
        let m = mode(["base", "more"]); let c = computer([m])
        let r = WindowState.resolve(computerRaw: c.id.uuidString, modeRaw: m.id.uuidString, layerRaw: "more",
                                    computers: [c], recentComputerID: c.id, recentModeID: m.id)
        XCTAssertEqual(r, .init(computerID: c.id, modeID: m.id, layerID: "more"))
    }

    func testDeletedComputerFallsBackToRecent() {
        let m = mode(["base"]); let c = computer([m])
        let r = WindowState.resolve(computerRaw: UUID().uuidString, modeRaw: UUID().uuidString, layerRaw: "x",
                                    computers: [c], recentComputerID: c.id, recentModeID: m.id)
        XCTAssertEqual(r.computerID, c.id)
        XCTAssertEqual(r.modeID, m.id)
        XCTAssertEqual(r.layerID, "base")
    }

    func testDeletedModeFallsBackToComputersFirstMode() {
        let m1 = mode(["base"]), m2 = mode(["base"]); let c = computer([m1, m2])
        let r = WindowState.resolve(computerRaw: c.id.uuidString, modeRaw: UUID().uuidString, layerRaw: nil,
                                    computers: [c], recentComputerID: c.id, recentModeID: m2.id)
        XCTAssertEqual(r.modeID, m1.id)
    }

    func testDeletedPageFallsBackToFirstPage() {
        let m = mode(["base", "more"]); let c = computer([m])
        let r = WindowState.resolve(computerRaw: c.id.uuidString, modeRaw: m.id.uuidString, layerRaw: "gone",
                                    computers: [c], recentComputerID: c.id, recentModeID: m.id)
        XCTAssertEqual(r.layerID, "base")
    }

    func testEmptyStorageUsesRecent() {
        let m1 = mode(["base"]), m2 = mode(["base"]); let c = computer([m1, m2], last: m2)
        let r = WindowState.resolve(computerRaw: "", modeRaw: "", layerRaw: "",
                                    computers: [c], recentComputerID: c.id, recentModeID: m2.id)
        XCTAssertEqual(r.modeID, m2.id, "没存过: 取这台电脑上次用的模式")
    }

    // 审计: 窗口存的模式被删时, 取这台电脑的第一个模式, 而不是 lastModeID。
    func testDeletedSavedModeUsesFirstModeEvenIfLastModeDiffers() {
        let m1 = mode(["base"]), m2 = mode(["base"]), m3 = mode(["base"])
        let c = computer([m1, m2, m3], last: m3)
        let r = WindowState.resolve(computerRaw: c.id.uuidString, modeRaw: UUID().uuidString, layerRaw: nil,
                                    computers: [c], recentComputerID: c.id, recentModeID: m3.id)
        XCTAssertEqual(r.modeID, m1.id, "§4.7: 模式不在了 → 这台电脑的第一个模式")
    }
}
