import XCTest

/// UI 交互验证 (用辅助功能 API 点击, 不受屏幕坐标/双显示器影响)。
/// 这些流程没法用单测覆盖 (要真点 sheet/menu/alert), 所以用 XCUITest 补齐。
/// App 带 `--uitest` 启动时用一份干净的 UserDefaults, 每次都是「一台默认电脑·一个默认模式」。
final class SidekeyUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest"]
        app.launch()
        return app
    }

    // 添加电脑: 点电脑圆圈行末的「…」(更多电脑) -> 手动添加 -> 填名字/地址 -> 保存 -> 列表里出现这台。
    func testAddComputerManuallyAppearsInList() {
        let app = launchApp()
        app.buttons["moreComputers"].firstMatch.tap()

        let addBtn = app.buttons["手动添加电脑"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 5), "应弹出电脑管理 sheet")
        addBtn.tap()

        let name = app.textFields["field.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "应进入添加电脑表单")
        name.tap(); name.typeText("测试电脑")
        let host = app.textFields["field.host"]
        host.tap(); host.typeText("10.0.0.5")
        app.buttons["保存"].tap()

        XCTAssertTrue(app.staticTexts["测试电脑"].waitForExistence(timeout: 5),
                      "保存后电脑列表里应出现「测试电脑」")
    }

    // 新建模式: 底部「模式」-> 模式管理 -> 加号 -> 输入名字 -> 创建 -> 列表里出现新模式。
    func testCreateModeFromModeManager() {
        let app = launchApp()
        app.buttons["modeButton"].tap()

        let addBtn = app.buttons["addModeButton"]
        XCTAssertTrue(addBtn.waitForExistence(timeout: 5), "模式管理应有加号")
        addBtn.tap()

        let alert = app.alerts["新建模式"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "应弹出新建模式对话框")
        let field = alert.textFields.firstMatch
        field.tap(); field.typeText("工作")
        alert.buttons["创建"].tap()

        XCTAssertTrue(app.staticTexts["工作"].waitForExistence(timeout: 5),
                      "创建后模式列表里应出现「工作」")
    }

    // 底部「设置」-> 汇总设置页 -> 编辑当前模式按键 -> 标题显示「<当前模式> · 按键」。
    func testEditKeysFromSettings() {
        let app = launchApp()
        app.buttons["settingsButton"].tap()

        let editRow = app.buttons["editKeysRow"]
        XCTAssertTrue(editRow.waitForExistence(timeout: 5), "设置页应有「编辑当前模式的按键」入口")
        editRow.tap()
        // 标题「<当前模式名> · 按键」。不硬编码模式名(默认种子可能变), 只校验后缀。
        let title = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "· 按键")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "编辑页标题应形如「<当前模式> · 按键」")
    }

    // 齿轮打开「外观」主题页, 含风格卡。
    func testAppearanceOpensFromGear() {
        let app = launchApp()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["外观"].waitForExistence(timeout: 5), "齿轮应打开外观页")
        XCTAssertTrue(app.buttons["styleCard_minimal"].waitForExistence(timeout: 5), "外观页应有风格卡")
    }

    // M2 第三轮 I3 / I4: 内屏 (--screen-inner) + 原键位有超出范围的旧键 (--fixture legacybounds)。
    // 从设置页真实打开编辑器: sheet 里拿到的是窗口的屏幕上下文, 标明「正在编辑原键位」;
    // 清空本页修好越界键后, 目标仍锁在原键位, 说明仍在 (原因更新); 返回再打开才编辑大屏键位 (生成发生在点击动作里)。
    func testInnerOriginalNoteSurvivesRepairAndReopenGeneratesLarge() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--screen-inner", "--fixture", "legacybounds"]
        app.launch()
        let notice = app.alerts["不能生成大屏键位"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        notice.buttons["知道了"].tap()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.buttons["editKeysRow"].waitForExistence(timeout: 5))
        app.buttons["editKeysRow"].tap()
        let note = app.staticTexts["editingOriginalOnInner"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "设置页弹出的编辑器也要拿到内屏上下文")
        XCTAssertTrue(note.label.contains("超出范围"))
        XCTAssertFalse(app.staticTexts["editingLargeLayout"].exists)
        app.buttons["editorMenu"].tap()
        app.buttons["清空本页"].tap()
        XCTAssertTrue(app.buttons["清空本页"].waitForExistence(timeout: 5))
        app.buttons["清空本页"].tap()
        XCTAssertTrue(note.waitForExistence(timeout: 5), "修好之后目标仍是原键位, 说明不能消失")
        XCTAssertFalse(note.label.contains("超出范围"), "原因随状态更新")
        XCTAssertFalse(app.staticTexts["editingLargeLayout"].exists, "不自动切换编辑目标")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "inner-original-note-after-repair"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["editorBack"].tap()
        XCTAssertTrue(app.buttons["editKeysRow"].waitForExistence(timeout: 5))
        app.buttons["editKeysRow"].tap()
        XCTAssertTrue(app.staticTexts["editingLargeLayout"].waitForExistence(timeout: 5), "重新打开: 点击时生成大屏键位并编辑它")
        XCTAssertFalse(note.exists)
    }

    // M3b: 内屏 (--screen-inner) 用大屏键位按 DuoLayout 排; 调换按钮切换并在重启后保持; 设置里有「内屏显示状态栏」开关
    func testInnerLayoutSwapPersistsAndStatusBarSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest", "--screen-inner"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["innerLayout"].waitForExistence(timeout: 10), "内屏排法")
        let tp = app.descendants(matching: .any)["innerTrackpad"].firstMatch, grid = app.descendants(matching: .any)["innerGrid"].firstMatch
        XCTAssertTrue(tp.waitForExistence(timeout: 5)); XCTAssertTrue(grid.exists)
        let kbAboveBefore = grid.frame.minY < tp.frame.minY
        app.buttons["swapButton"].tap()
        let swapped = NSPredicate { _, _ in (grid.frame.minY < tp.frame.minY) != kbAboveBefore }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: swapped, object: nil)], timeout: 5), .completed, "调换: 键盘和触控板换位")
        app.terminate(); app.launch()                                      // 重启后恢复 (全局保存)
        XCTAssertTrue(tp.waitForExistence(timeout: 10))
        XCTAssertNotEqual(grid.frame.minY < tp.frame.minY, kbAboveBefore, "调换偏好重启后保留")
        app.buttons["swapButton"].tap()                                    // 还原, 免得影响别的用例
        Thread.sleep(forTimeInterval: 0.6)                                 // 调换动画期间整个界面不接受输入 (§4.4, M3 审计 I6)
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["innerStatusBarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "内屏上设置里有「内屏显示状态栏」")
        XCTAssertEqual(toggle.value as? String, "0", "默认关")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.switches.firstMatch.tap()                                   // 还原
    }

    // MARK: - M3 第二轮审计: 用实际呈现补强证据

    private func launch(_ args: [String]) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--uitest"] + args; app.launch(); return app
    }

    // 调换动画期间, 点顶栏 (设置) 和胶囊 (语音) 都无效 (§4.4; --slow-swap 把动画拉长到 1.5 秒, 结果稳定)
    func testSwapAnimationLocksTopBarAndDock() {
        let app = launch(["--screen-inner", "--slow-swap"])
        XCTAssertTrue(app.buttons["swapButton"].waitForExistence(timeout: 10))
        app.buttons["swapButton"].tap()
        app.buttons["settingsButton"].tap()
        app.buttons["dockMic"].firstMatch.tap()
        XCTAssertFalse(app.buttons["editKeysRow"].waitForExistence(timeout: 1.5), "动画期间点设置无效")
        XCTAssertFalse(app.textViews["voiceText"].exists, "动画期间点语音无效")
        app.buttons["swapButton"].tap()                                   // 动画结束后还原
        sleep(2)
    }

    // R-B1: 键盘开着 / 收着各往返 20 次 (--test-screen-bounce: 语音打开 8 秒后每 2.5 秒自动换屏, 共 40 次)。
    // App 在每次换屏 2 秒后记下当前容器输入框的实际状态, 结束后整段给出; 这里逐次断言文字、选区、键盘 (第一响应者) 状态,
    // 最后关闭按钮能响应 (没有卡死在焦点循环里)
    private func bounce(keepKeyboard: Bool) throws {
        let app = launch(["--screen-inner", "--assume-connected", "--test-screen-bounce"])
        XCTAssertTrue(app.buttons["dockMic"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["dockMic"].firstMatch.tap()
        let inner = app.textViews["voiceText"]
        XCTAssertTrue(inner.waitForExistence(timeout: 5))
        inner.tap(); inner.typeText("0123456789")
        if !keepKeyboard { app.buttons["voiceHideKeyboard"].tap() }
        let log = app.staticTexts["testBounce"]
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "done;"), object: log)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 150), .completed, "40 次换屏没有按时做完 (界面卡住?)")
        let rounds = log.label.components(separatedBy: ";").dropFirst()
        XCTAssertEqual(rounds.count, 40)
        for (n, r) in rounds.enumerated() {
            let i = n + 1, f = r.components(separatedBy: ",")
            XCTAssertEqual(f.first, i % 2 == 1 ? "phoneVoiceText" : "voiceText", "第 \(i) 次: 容器 (\(r))")
            guard f.count == 5 else { XCTFail("第 \(i) 次: 输入框不在 (\(r))"); continue }
            XCTAssertEqual(f[1], "0123456789", "第 \(i) 次: 文字")
            XCTAssertEqual(f[2], "10", "第 \(i) 次: 选区位置"); XCTAssertEqual(f[3], "0", "第 \(i) 次: 选区长度")
            XCTAssertEqual(f[4], keepKeyboard ? "1" : "0", "第 \(i) 次: 键盘应\(keepKeyboard ? "保持打开" : "保持收起")")
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "bounce-\(keepKeyboard ? "open" : "hidden")"; shot.lifetime = .keepAlways; add(shot)
        let close = app.buttons["voiceClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 3)); close.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: inner)], timeout: 3), .completed, "关闭按钮能响应")
    }
    func testScreenBounceKeyboardOpen() throws { try bounce(keepKeyboard: true) }
    func testScreenBounceKeyboardHidden() throws { try bounce(keepKeyboard: false) }

    // 跨屏: 草稿、收起的键盘都跟着走 (实际呈现的 sheet 和面板)
    func testCrossScreenVoiceRealPresentation() {
        let app = launch(["--screen-inner", "--test-screen-toggle"])
        XCTAssertTrue(app.buttons["dockMic"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["dockMic"].firstMatch.tap()
        let inner = app.textViews["voiceText"]
        XCTAssertTrue(inner.waitForExistence(timeout: 5))
        inner.typeText("KEEP-ME")
        app.buttons["voiceHideKeyboard"].tap()
        sleep(1)
        app.buttons["testToggleScreen"].tap()
        let phone = app.textViews["phoneVoiceText"]
        XCTAssertTrue(phone.waitForExistence(timeout: 5), "换到手机屏后用 sheet 呈现")
        XCTAssertEqual(phone.value as? String, "KEEP-ME", "草稿跟着走")
        sleep(1)
        XCTAssertEqual(app.keyboards.count, 0, "原来收起的键盘不会自动弹出")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "cross-screen-voice-phone"; shot.lifetime = .keepAlways; add(shot)
    }

    // 内屏但暂用原键位 (越界旧键) 时, 语音仍能打开 (手机 sheet)
    func testLegacyFallbackOnInnerOpensVoice() {
        let app = launch(["--screen-inner", "--fixture", "legacybounds"])
        let a = app.alerts["不能生成大屏键位"]
        XCTAssertTrue(a.waitForExistence(timeout: 8)); a.buttons["知道了"].tap()
        app.buttons["dockMic"].firstMatch.tap()
        XCTAssertTrue(app.textViews["phoneVoiceText"].waitForExistence(timeout: 5))
    }

    // 权限面板: 从内屏的键旁弹出, 换屏后仍在 (实际呈现), 关闭按钮可点
    func testPaletteRealHandover() throws {
        let app = launch(["--screen-inner", "--assume-connected", "--test-toggle-on-palette", "--test-screen-toggle"])   // 打开 1 秒后自动换屏 (不靠点击, 点击会被浮层吃掉)
        let key = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "权限 ·")).firstMatch   // 网格键没有按钮特征, 按键面文字找
        XCTAssertTrue(key.waitForExistence(timeout: 10)); key.tap()
        let title = app.staticTexts["权限模式"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        sleep(3)
        XCTAssertEqual(app.buttons["testToggleScreen"].label, "→内屏", "确实换到了手机屏")
        XCTAssertTrue(title.exists, "换屏后面板转交给手机 sheet")
        // 面板外层的标识 (permissionPalette) 会盖掉按钮自己的, 按「关闭」标签找
        let all = app.buttons.matching(NSPredicate(format: "label == %@", "关闭"))
        let closes = all.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(closes.count, 1, "只有当前容器 (手机 sheet) 的关闭按钮可点 (共 \(all.count) 个)")
        let close = try XCTUnwrap(closes.first)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44); XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)], timeout: 3), .completed)
    }
}
