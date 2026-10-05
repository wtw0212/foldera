import AVFoundation
import Quartz
import AppKit
import SwiftUI
import Testing
import ViewInspector
@testable import Foldera

/// Verify the view output and control bindings, in addition to the native UI smoke tests.
@MainActor
struct SwiftUIViewTests {
    private func texts<V: View>(_ view: V) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func generalSettingsExposeLanguagesLocationsAndPersistSelection() throws {
        let preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        let view = GeneralSettings(settings: settings)
        let labels = try texts(view)
        for language in AppLanguage.allCases { #expect(labels.contains(language.title)) }
        for location in StartLocation.allCases { #expect(labels.contains(location.title)) }
        let pickers = try view.inspect().findAll(ViewType.Picker.self)
        #expect(pickers.count == 5)
        try pickers[0].select(value: AppLanguage.traditionalChinese)
        try pickers[1].select(value: StartLocation.downloads)
        try pickers[2].select(value: 10)
        try pickers[3].select(value: true)
        #expect(settings.recentItemsCount == 10 && preferences.defaults.integer(forKey: "recentItemsCount") == 10)
        #expect(settings.language == .traditionalChinese && settings.startLocation == .downloads)
        #expect(settings.returnKeyRenames && preferences.defaults.bool(forKey: "returnKeyRenames"))
    }

    @Test func viewSettingsPersistAllFourDisplayToggles() throws {
        let preferences = try TestPreferences()
        let settings = AppSettings(defaults: preferences.defaults)
        let view = ViewSettings(settings: settings)
        let toggles = try view.inspect().findAll(ViewType.Toggle.self)
        #expect(toggles.count == 5)
        #expect(!settings.autoplayPreviews, "videos don't play on their own by default")
        for toggle in toggles { try toggle.tap() }
        #expect(settings.showHiddenFiles && !settings.showExtensions && settings.compactView && !settings.showNavigationPane)
        #expect(settings.autoplayPreviews && AppSettings(defaults: preferences.defaults).autoplayPreviews)
        #expect(settings.rowHeight == 22)
        #expect(try texts(view).contains(L10n.text("Reset All Folders")))
    }

    @Test func cloudSettingsShowAnEmptyStateAndRemoveOnlyTheChosenCustomFolder() throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let storage = try directory.folder("providers"), folder = try directory.folder("custom")
        let cloud = CloudDrives(defaults: preferences.defaults, storageFolder: storage)
        #expect(try texts(CloudSettings(cloud: cloud)).contains(L10n.text("None found")))
        cloud.add(folder)
        let view = CloudSettings(cloud: cloud)
        #expect(try texts(view).contains("custom"))
        try view.inspect().find(button: L10n.text("Remove")).tap()
        #expect(!cloud.isAdded(folder) && cloud.locations.isEmpty)
        #expect(try view.inspect().findAll(ViewType.Button.self).count >= 4)
    }

    @Test func settingsContainsFourSectionsIncludingPermissionGuidance() throws {
        let labels = try texts(SettingsView())
        #expect(labels.contains(L10n.text("F2 always renames. ⌘↓ always opens.")))
        #expect(labels.contains(L10n.text("Show hidden items")))
        #expect(labels.contains(L10n.text("With Full Disk Access, macOS stops asking for permission folder by folder.")))
    }

    @Test func welcomePagesShowTheTourAndFinishCallback() throws {
        #expect(try texts(WelcomeView {}).contains(L10n.text("Welcome to Foldera")))
        let tour = try texts(WelcomeView(page: 1) {})
        for title in ["A quick tour", "Tabs and dual pane", "Address bar", "Archives", "Bulk rename", "This Mac and cloud drives"] {
            #expect(tour.contains(L10n.text(title)))
        }
        var finished = false
        let last = WelcomeView(page: 2) { finished = true }
        #expect(try texts(last).contains(L10n.text("Full Disk Access")))
        try last.inspect().find(button: L10n.text("Get Started")).tap()
        #expect(finished && WelcomeView.hasBeenSeen)
        finished = false
        try WelcomeView { finished = true }.inspect().find(button: L10n.text("Skip")).tap()
        #expect(finished)
    }

    @Test func bulkRenamePreviewsEveryRuleAndRejectsInvalidNames() throws {
        let directory = try TestDirectory()
        let urls = [try directory.file("one.txt"), try directory.file("two.txt")]
        for url in urls {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
        }
        let items = urls.map(FileItem.init(url:))
        for mode in BulkRenameRule.Mode.allCases {
            var rule = BulkRenameRule()
            rule.mode = mode
            rule.find = "one"
            rule.replaceWith = "first"
            rule.addText = "prefix-"
            rule.customFormat = "Report"
            for style in BulkRenameRule.FormatStyle.allCases {
                rule.formatStyle = style
                let view = BulkRenameSheet(items: items, rule: rule) { _ in }
                let labels = try texts(view)
                for name in BulkRename.newNames(for: items.map { .init(url: $0.url, date: $0.dateModified) }, rule: rule) {
                    #expect(labels.contains(name))
                }
                // Equal modification dates produce a duplicate date-format name; the sheet must block it.
                #expect(try view.inspect().find(button: L10n.text("Rename")).isDisabled() == (mode == .format && style == .date))
            }
        }
        var invalid = BulkRenameRule()
        invalid.mode = .format
        invalid.customFormat = "bad/name"
        #expect(try BulkRenameSheet(items: items, rule: invalid) { _ in }.inspect().find(button: L10n.text("Rename")).isDisabled())
        #expect(try BulkRenameSheet(items: items) { _ in }.inspect().find(button: L10n.text("Rename")).isDisabled())
    }

    @Test func bulkRenameButtonChangesFilesAndReportsTheActualDestinations() throws {
        let directory = try TestDirectory()
        let original = try directory.file("before.txt", contents: "preserved")
        var rule = BulkRenameRule()
        rule.find = "before"
        rule.replaceWith = "after"
        var destinations: [URL] = []
        let view = BulkRenameSheet(items: [FileItem(url: original)], rule: rule) { destinations = $0 }
        try view.inspect().find(button: L10n.text("Rename")).tap()
        #expect(destinations.map(\.lastPathComponent) == ["after.txt"])
        #expect(try String(contentsOf: directory.path("after.txt"), encoding: .utf8) == "preserved")
        #expect(!FileOperations.exists(original))
    }

    @Test func compressSheetOffersOptionsAndBlocksBadNamesAndPasswords() throws {
        let directory = try TestDirectory()
        let file = try directory.file("note.txt", contents: "hi")
        let other = try directory.file("other.txt", contents: "hi")
        var result: (options: Archives.Options, name: String, folder: URL)?
        let view = CompressSheet(items: [file], fallbackFolder: directory.url) { result = ($0, $1, $2) }
        let labels = try texts(view)
        #expect(labels.contains(L10n.format("Compress “%@”", "note.txt")))
        #expect(labels.contains(L10n.text("Archive name:")) && labels.contains(L10n.text("Password:")))
        try view.inspect().find(button: L10n.text("Compress")).tap()
        #expect(result?.name == "note.txt" && result?.folder.lastPathComponent == directory.url.lastPathComponent)
        #expect(result?.options.hasPassword == false)
        #expect(labels.contains(".zip"))
        for name in ["backup.zip", " backup.ZIP "] {
            #expect(try !texts(CompressSheet(items: [file], fallbackFolder: directory.url, name: name) { _, _, _ in }).contains(".zip"))
        }

        #expect(try texts(CompressSheet(items: [file, other], fallbackFolder: directory.url) { _, _, _ in })
            .contains(L10n.format("Compress %lld items", 2)))
        func isBlocked(name: String? = nil, password: String = "", confirmation: String = "") throws -> Bool {
            try CompressSheet(items: [file], fallbackFolder: directory.url, name: name, password: password, confirmation: confirmation) { _, _, _ in }
                .inspect().find(button: L10n.text("Compress")).isDisabled()
        }
        #expect(try isBlocked(name: " "))
        #expect(try isBlocked(name: "bad/name"))
        #expect(try isBlocked(password: "secret", confirmation: "secrex"))
        #expect(try !isBlocked(password: "secret", confirmation: "secret"))
        // The encryption choice is there before a password is typed, but only usable with one.
        let encryption = try view.inspect().find(ViewType.Picker.self) { try $0.labelView().text().string() == L10n.text("Encryption:") }
        #expect(encryption.isDisabled())
    }

    @Test func detailsPaneDescribesEmptySingleFolderAndMultipleFileSelections() async throws {
        let directory = try TestDirectory(), preferences = try TestPreferences()
        let file = try directory.file("note.txt", contents: "hi"), folder = try directory.folder("nested")
        let tab = BrowserTab(url: directory.url, settings: AppSettings(defaults: preferences.defaults))
        try await eventually { !tab.isLoading }
        #expect(try texts(DetailsPane(tab: tab)).contains(L10n.text("Items")))
        tab.selection = [folder]
        #expect(try texts(DetailsPane(tab: tab)).contains("nested"))
        #expect(try texts(DetailsPane(tab: tab)).contains(L10n.text("Properties")))
        tab.selection = [file, folder]
        #expect(try texts(DetailsPane(tab: tab)).contains(L10n.format("items.selected", 2)))
        #expect(try texts(DetailsPane(tab: tab)).contains(L10n.text("Size")))
        tab.selection = [file]
        #expect(try texts(DetailsPane(tab: tab)).contains("note.txt"))
        tab.navigate(to: BrowserTab.thisMacURL)
        #expect(try texts(DetailsPane(tab: tab)).contains(L10n.text("Drives")))
    }

    @Test func driveTileShowsCapacityAndAccessibleFreeSpace() throws {
        let location = Location(url: URL(fileURLWithPath: "/"), title: "Test Drive", symbol: "externaldrive", tint: .blue)
        let loading = DriveTile(drive: location, usage: nil, isSelected: false)
        #expect(try texts(loading).contains("Test Drive"))
        let usage = DriveUsage(total: 100_000_000_000, available: 25_000_000_000, isNetwork: false)
        let view = DriveTile(drive: location, usage: usage, isSelected: true)
        let expected = L10n.format("%@ free of %@", DriveTile.format(usage.available), DriveTile.format(usage.total))
        #expect(try texts(view).contains(expected))
        #expect(try view.inspect().find(ViewType.HStack.self).accessibilityValue().string() == expected)
    }

    @Test func transferRowShowsProgressSpeedAndCancellationState() throws {
        let transfer = FileTransfer(kind: .copy, itemCount: 2, source: URL(fileURLWithPath: "/tmp/source"), destination: URL(fileURLWithPath: "/tmp/destination"))
        transfer.totalBytes = 100
        transfer.progress.setCompleted(25)
        transfer.progress.setCurrentName("sample.txt")
        transfer.refresh()
        let row = TransferRow(transfer: transfer)
        #expect(try texts(row).contains(L10n.format("%lld%% complete", 25)))
        #expect(try texts(row).contains(L10n.format("Name: %@", "sample.txt")))
        try row.inspect().find(ViewType.Button.self).tap()
        #expect(transfer.isCancelled)
        #expect(try texts(row).contains(L10n.text("Cancelling…")))
        #expect(try row.inspect().find(ViewType.Button.self).isDisabled())
    }
}

@MainActor
struct PreviewPlaybackTests {
    @Test func previewsDoNotAutostartUnlessAskedTo() throws {
        let file = try TestDirectory().file("clip.txt")
        let off = QuickLookPreview(url: file)
        #expect(!off.autostarts)
        let host = NSHostingView(rootView: off.frame(width: 200, height: 200))
        host.layoutSubtreeIfNeeded()
        let view = try #require(host.subviews.first { $0 is QLPreviewView } as? QLPreviewView ?? Self.find(in: host))
        #expect(!view.autostarts)
        host.rootView = QuickLookPreview(url: file, autostarts: true).frame(width: 200, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(view.autostarts)
    }

    @Test func videosShowAPlayButtonAndClickingThePictureTogglesPlayback() throws {
        let file = try TestDirectory().file("clip.mov")
        let playback = VideoPlayback(url: file)
        let preview = VideoPreview(playback: playback)
        #expect(try preview.inspect().vStack().zStack(0).image(1).actualImage().name() == "play.circle.fill", "paused videos show a play button")
        try preview.inspect().vStack().zStack(0).callOnTapGesture()
        #expect(playback.isPlaying)
        #expect((try? preview.inspect().vStack().zStack(0).image(1)) == nil, "the button hides while playing")
        try preview.inspect().vStack().zStack(0).callOnTapGesture()
        #expect(!playback.isPlaying, "clicking again pauses")
        let timeline = try preview.inspect().vStack().hStack(1)
        #expect(try timeline.text(0).string() == "0:00" && timeline.slider(1).isDisabled(), "no timeline until the video loads")

        let host = NSHostingView(rootView: VideoPreview(url: file).frame(width: 200, height: 200))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
        #expect(FileKind.of(file, type: nil) == .video)
    }

    @Test func videoPlaybackPlaysPausesAndRewindsAtTheEnd() {
        let playback = VideoPlayback(url: URL(fileURLWithPath: "/nonexistent/clip.mov"))
        #expect(!playback.isPlaying)
        playback.toggle()
        #expect(playback.isPlaying)
        playback.toggle()
        #expect(!playback.isPlaying)
        playback.play()
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: playback.player.currentItem)
        #expect(!playback.isPlaying, "the end shows the play button again")
        playback.seek(to: 3.5)
        #expect(playback.currentTime == 3.5)
        playback.tick(CMTime(seconds: 1, preferredTimescale: 600))
        #expect(playback.currentTime == 1)
        playback.isScrubbing = true
        playback.tick(CMTime(seconds: 2, preferredTimescale: 600))
        #expect(playback.currentTime == 1, "dragging the timeline isn't overridden by playback")
        #expect(VideoPlayback.format(7.9) == "0:07" && VideoPlayback.format(3723) == "1:02:03" && VideoPlayback.format(.nan) == "0:00")
    }

    @Test func videoTimelineLoadsTheLengthAndSeeks() async throws {
        let directory = try TestDirectory(), video = directory.path("clip.mov")
        try await Self.writeVideo(to: video, seconds: 2)
        let playback = VideoPlayback(url: video)
        try await eventually { playback.duration > 1.9 }
        playback.seek(to: 10)
        #expect(playback.currentTime == playback.duration, "seeking stops at the end")
        let host = NSHostingView(rootView: VideoPreview(playback: playback).frame(width: 240, height: 286))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    /// A short black video, so tests don't need a fixture file.
    private static func writeVideo(to url: URL, seconds: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0...(seconds * 10) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            adaptor.append(try #require(buffer), withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }

    private static func find(in view: NSView) -> QLPreviewView? {
        (view as? QLPreviewView) ?? view.subviews.lazy.compactMap(find).first
    }
}
