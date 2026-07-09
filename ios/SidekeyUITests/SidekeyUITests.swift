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

    // 添加电脑: 点电脑 chip -> 手动添加 -> 填名字/地址 -> 保存 -> 列表里出现这台。
    func testAddComputerManuallyAppearsInList() {
        let app = launchApp()
        app.buttons["computerChip"].tap()

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
}
