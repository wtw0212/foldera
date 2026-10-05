import AppKit
import XCTest

private extension XCUIElement {
    /// Avoid XCTest's polling wait when the element is already present.
    func waitForAppearance(timeout: TimeInterval) -> Bool {
        exists || waitForExistence(timeout: timeout)
    }
}

@MainActor
private func enter(_ text: String, into field: XCUIElement) {
    // Hosted CI has a disposable clipboard; local runs keep typing without changing it.
    guard ProcessInfo.processInfo.environment["FOLDERA_CI"] == "true" else {
        field.typeText(text)
        return
    }
    NSPasteboard.general.clearContents()
    XCTAssertTrue(NSPasteboard.general.setString(text, forType: .string))
    field.typeKey("v", modifierFlags: .command)
}

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
        XCTAssertTrue(app.tables["file-list"].waitForAppearance(timeout: 10))
        XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForAppearance(timeout: 5))
        try test(app, root)
    }

    private func navigate(_ app: XCUIApplication, to path: String) {
        app.typeKey("l", modifierFlags: .command)
        let address = app.textFields["address-field"]
        XCTAssertTrue(address.waitForAppearance(timeout: 5))
        enter(path, into: address)
        address.typeKey(.return, modifierFlags: [])
    }

    func testAddressNavigationAndBackForwardButtons() throws {
        try withApp { app, root in
            let back = app.buttons["navigate-back"], forward = app.buttons["navigate-forward"]
            XCTAssertFalse(back.isEnabled)
            navigate(app, to: root.appendingPathComponent("nested").path)
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForAppearance(timeout: 5))
            XCTAssertTrue(back.isEnabled)
            back.click()
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForAppearance(timeout: 5))
            XCTAssertTrue(forward.isEnabled)
            forward.click()
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForAppearance(timeout: 5))
        }
    }

    func testRecursiveSearchAndEscapeRestoreTheListing() throws {
        try withApp { app, _ in
            app.typeKey("f", modifierFlags: .command)
            let search = app.textFields["search-field"]
            search.typeText("report")
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForAppearance(timeout: 5))
            XCTAssertFalse(app.tables["file-list"].staticTexts["note.txt"].exists)
            search.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForAppearance(timeout: 5))
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
            XCTAssertTrue(app.tables["file-list"].staticTexts["note.txt"].waitForAppearance(timeout: 5))
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

    func testCommandPlusAndMinusSwitchBetweenListAndIcons() throws {
        try withApp { app, _ in
            app.typeKey("=", modifierFlags: .command)
            app.typeKey("=", modifierFlags: .command)
            let gone = NSPredicate { _, _ in !app.tables["file-list"].exists }
            expectation(for: gone, evaluatedWith: app)
            waitForExpectations(timeout: 5)
            app.typeKey("-", modifierFlags: .command)
            app.typeKey("-", modifierFlags: .command)
            XCTAssertTrue(app.tables["file-list"].waitForAppearance(timeout: 5))
        }
    }

    func testTraditionalChineseStatusAndAddressNavigation() throws {
        try withApp(language: "zh-Hant") { app, root in
            XCTAssertEqual(app.staticTexts["item-count"].value as? String, "2 個項目")
            navigate(app, to: root.appendingPathComponent("nested").path)
            XCTAssertTrue(app.tables["file-list"].staticTexts["report.txt"].waitForAppearance(timeout: 5))
            XCTAssertEqual(app.staticTexts["item-count"].value as? String, "1 個項目")
        }
    }

    func testServerFileCommandsAreLocalizedAndDisabledWithoutSessions() throws {
        for (language, menu, finish, resume, show) in [
            ("en", "Server Files", "Finish Editing Server Files", "Resume Recovered Edits", "Show Server Files"),
            ("zh-Hant", "伺服器檔案", "結束編輯伺服器檔案", "恢復已復原的編輯", "顯示伺服器檔案"),
        ] {
            try withApp(language: language) { app, _ in
                app.menuBars.menuBarItems.element(boundBy: 1).click()
                let submenu = app.menuItems[menu]
                XCTAssertTrue(submenu.waitForAppearance(timeout: 5))
                submenu.hover()
                for title in [finish, resume, show] {
                    let command = app.menuItems[title]
                    XCTAssertTrue(command.waitForAppearance(timeout: 5))
                    XCTAssertFalse(command.isEnabled)
                }
                app.menuBars.firstMatch.typeKey(.escape, modifierFlags: [])
            }
        }
    }
}

/// Connects through the real UI to the throwaway OpenSSH server that scripts/test.sh starts
/// (UI tests are sandboxed and can't run a server themselves).
final class NetworkUITests: XCTestCase {
    @MainActor
    func testSFTPAddressSavesASiteTrustsTheServerAndListsFiles() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let port = environment["FOLDERA_SFTP_PORT"], let key = environment["FOLDERA_SFTP_KEY"],
              let served = environment["FOLDERA_SFTP_ROOT"] else {
            throw XCTSkip("Run with scripts/test.sh ui, which starts the SFTP server.")
        }
        let app = XCUIApplication()
        defer {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "SFTP"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
        app.launchArguments = [
            "-initialPath", NSTemporaryDirectory(), "-appLanguage", "en",
            "-hasSeenWelcome", "YES", "-fullDiskAccessBannerDismissed", "YES",
            "-defaultViewMode", "details", "-folderViewModes", "{}",
            "-showNavigationPane", "NO", "-sidePane", "none", "-showHiddenFiles", "NO",
            // Start without saved sites or trusted servers.
            "-sftpSites", "<>", "-sftpHostKeys", "{}",
        ]
        app.launch()
        XCTAssertTrue(app.tables["file-list"].waitForAppearance(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let address = app.textFields["server-address"]
        XCTAssertTrue(address.waitForAppearance(timeout: 5))
        enter("sftp://\(NSUserName())@127.0.0.1:\(port)\(served)", into: address)
        address.typeKey(.return, modifierFlags: [])

        let host = app.textFields["site-host"]
        XCTAssertTrue(host.waitForAppearance(timeout: 5))
        XCTAssertEqual(host.value as? String, "127.0.0.1")
        app.radioButtons["Private key"].click()
        let keyField = app.textFields["site-key"]
        XCTAssertTrue(keyField.waitForAppearance(timeout: 5))
        keyField.click()
        enter(key, into: keyField)
        app.buttons["Save and Connect"].click()

        let trust = app.buttons["Trust and Connect"].firstMatch
        XCTAssertTrue(trust.waitForAppearance(timeout: 15))
        trust.click()
        XCTAssertTrue(app.tables["file-list"].staticTexts["remote.txt"].waitForAppearance(timeout: 15))
        XCTAssertEqual(app.staticTexts["item-count"].value as? String, "1 item")
    }
}
