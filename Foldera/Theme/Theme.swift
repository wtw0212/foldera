import AppKit
import SwiftUI

/// Windows 11 File Explorer palette. Every color resolves for both light and dark appearance.
enum Theme {
    static let fontSize: CGFloat = 12
    static let font = Font.system(size: fontSize)
    static let nsFont = NSFont.systemFont(ofSize: fontSize)

    /// Tab strip / Mica layer behind everything.
    static let mica = dynamic(light: 0xEEF1F6, dark: 0x1C1F24)
    /// The raised layer that holds the selected tab, address row and command bar.
    static let layer = dynamic(light: 0xF9F9F9, dark: 0x2B2B2B)
    /// File list and navigation pane background.
    static let content = dynamic(light: 0xFFFFFF, dark: 0x191919)
    static let divider = dynamic(light: 0xE5E5E5, dark: 0x333333)
    static let controlFill = dynamic(light: 0xFFFFFF, dark: 0x2D2D2D)
    static let controlStroke = dynamic(light: 0xE0E0E0, dark: 0x3A3A3A)
    static let hover = dynamic(light: 0xE5F3FF, dark: 0x2D2D2D)
    static let selection = dynamic(light: 0xCCE8FF, dark: 0x36404C)
    static let selectionHover = dynamic(light: 0xB9DFFF, dark: 0x3E4A58)
    /// Selection while the list is not focused.
    static let selectionInactive = dynamic(light: 0xE3E3E3, dark: 0x343434)
    static let subtleHover = dynamic(light: 0x000000, alphaLight: 0.05, dark: 0xFFFFFF, alphaDark: 0.06)
    static let subtlePressed = dynamic(light: 0x000000, alphaLight: 0.08, dark: 0xFFFFFF, alphaDark: 0.09)
    static let text = dynamic(light: 0x1A1A1A, dark: 0xFFFFFF)
    static let secondaryText = dynamic(light: 0x616161, dark: 0xC5C5C5)
    static let tertiaryText = dynamic(light: 0x8A8A8A, dark: 0x9A9A9A)
    static let accent = dynamic(light: 0x0067C0, dark: 0x4CC2FF)
    static let folderBack = dynamic(light: 0xE8A93C, dark: 0xD99A2B)
    static let folderFront = dynamic(light: 0xFFCB4C, dark: 0xF5BC3C)

    /// Nonisolated: AppKit and SwiftUI resolve dynamic colors on render threads, not only the main thread.
    nonisolated static func dynamic(light: UInt32, alphaLight: CGFloat = 1, dark: UInt32, alphaDark: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? alphaDark : alphaLight)
        }
    }
}

extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    var swiftUI: Color { Color(nsColor: self) }
}
