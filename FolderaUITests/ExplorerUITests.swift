import XCTest

@MainActor
final class ExplorerUITests: XCTestCase {
    private func withApp(language: String = "en", _ test: (XCUIApplication, URL) throws -> Void) throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderaUI-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("note".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("report".utf8).write(to: root.appendingPathComponent("nested/report.txt"))
        let app = XCUIApplication()
        defer {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Explorer"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        app.launchArguments = [
            "-initialPath", root.path, "-appLanguage", language,
            "-hasSeenWelcome", "YES", "-fullDiskAccessBannerDismissed", "YES",
            "-defaultViewMode", "details", "-folderViewModes", "{}",
            "-showNavigationPane", "NO", "-sidePane", "none", "-showHiddenFiles", "NO",
            "-showExtensions", "YES",
        ]
        app.launch()
        XCTAssertTrue(app.tables["file-list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForExistence(timeout: 5))
        try test(app, root)
    }

    private func navigate(_ app: XCUIApplication, to path: String) {
        app.typeKey("l", modifierFlags: .command)
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.typeText(path)
        address.typeKey(.return, modifierFlags: [])
    }

    func testAddressNavigationAndBackForwardButtons() throws {
        try withApp { app, root in
            let back = app.buttons["navigate-back"], forward = app.buttons["navigate-forward"]
            XCTAssertFalse(back.isEnabled)
            navigate(app, to: root.appendingPathComponent("nested").path)
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForExistence(timeout: 5))
            XCTAssertTrue(back.isEnabled)
            back.click()
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForExistence(timeout: 5))
            XCTAssertTrue(forward.isEnabled)
            forward.click()
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForExistence(timeout: 5))
        }
    }

    func testRecursiveSearchAndEscapeRestoreTheListing() throws {
        try withApp { app, _ in
            app.typeKey("f", modifierFlags: .command)
            let search = app.textFields["search-field"]
            search.typeText("report")
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.tables["file-list"].staticTexts["note.txt"].exists)
            search.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForExistence(timeout: 5))
        }
    }

    func testNewAndCloseTabKeyboardShortcuts() throws {
        try withApp { app, root in
            XCTAssertEqual(app.staticTexts.matching(identifier: "tab-title").count, 1)
            app.typeKey("t", modifierFlags: .command)
            let twoTabs = NSPredicate { _, _ in app.staticTexts.matching(identifier: "tab-title").count == 2 }
            expectation(for: twoTabs, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            navigate(app, to: root.path)
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForExistence(timeout: 5))
            app.typeKey("w", modifierFlags: .command)
            let oneTab = NSPredicate { _, _ in app.staticTexts.matching(identifier: "tab-title").count == 1 }
            expectation(for: oneTab, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.windows.firstMatch.exists)
        }
    }

    func testNewFolderShortcutAndUndoChangeTheFilesystem() throws {
        try withApp { app, root in
            app.typeKey("n", modifierFlags: [.command, .shift])
            let folder = root.appendingPathComponent("New folder")
            let created = NSPredicate { _, _ in FileManager.default.fileExists(atPath: folder.path) }
            expectation(for: created, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            app.typeKey(.escape, modifierFlags: [])
            app.typeKey("z", modifierFlags: .command)
            let undone = NSPredicate { _, _ in !FileManager.default.fileExists(atPath: folder.path) }
            expectation(for: undone, evaluatedWith: app)
            waitForExpectations(timeout: 5)
        }
    }

    func testTraditionalChineseStatusAndAddressNavigation() throws {
        try withApp(language: "zh-Hant") { app, root in
            XCTAssertEqual(app.staticTexts["item-count"].value as? String, "2 個項目")
            navigate(app, to: root.appendingPathComponent("nested").path)
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["item-count"].value as? String, "1 個項目")
        }
    }
}
