import XCTest

final class SidebarUITests: XCTestCase {
    @MainActor
    func testThemeSelectionUpdatesAndPersists() {
        let app = XCUIApplication()
        app.launchArguments = ["--mute", "--show-settings"]
        app.launch()
        let light = app.buttons["浅色"]
        XCTAssertTrue(light.waitForExistence(timeout: 10))
        let names = ["浅色", "深色", "跟随系统"]
        let original = names.first { app.buttons[$0].isSelected } ?? "跟随系统"
        for name in names {
            app.buttons[name].tap()
            XCTAssertTrue(app.buttons[name].isSelected, "Theme must select \(name)")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "主题-\(name)"; shot.lifetime = .keepAlways
            add(shot)
        }
        light.tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(light.waitForExistence(timeout: 10))
        XCTAssertTrue(light.isSelected, "Theme persists across relaunch")
        app.buttons[original].tap()
    }

    @MainActor
    func testContentSwipeOpensSidebarAndSettingsAreSimplified() {
        let app = XCUIApplication()
        app.launchArguments = ["--mute", "--ui-fixture-results"]
        app.launch()
        XCTAssertTrue(app.buttons["打开菜单"].waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
        // A vertical scroll must not open the sidebar.
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.3)))
        XCTAssertFalse(app.buttons["关闭菜单"].exists)
        // Start well away from the old 24-point edge-only region.
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(app.buttons["关闭菜单"].waitForExistence(timeout: 3))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.switches["中文资源优先"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.switches["内置引擎（无需电脑）"].exists)
        XCTAssertFalse(app.textFields["http://192.168.1.10:8765"].exists)
        XCTAssertTrue(app.buttons["连接电脑（高级）"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "简化设置真机"; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testEmptyContentSwipeOpensSidebar() {
        let app = XCUIApplication()
        app.launchArguments = ["--mute"]
        app.launch()
        XCTAssertTrue(app.buttons["打开菜单"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45)))
        XCTAssertTrue(app.buttons["关闭菜单"].waitForExistence(timeout: 3))
        app.buttons["关闭菜单"].tap()
        XCTAssertFalse(app.buttons["关闭菜单"].exists)
    }
}
