import AppKit
import SwiftUI

// The shared design language: Liquid Glass for chrome that floats (panels, toolbars, controls),
// solid system surfaces for the content you read. Everything follows light and dark mode.
// Characters differ by accent colour and by what they show, not by restyling the system.

extension NSColor {
    /// One colour for light mode and one for dark.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

/// Xcode's default source colours, so code reads the way it does in Xcode.
enum CodePalette {
    static let text = NSColor.textColor
    static let comment = NSColor.adaptive(light: NSColor(rgb: 0x5D6C79), dark: NSColor(rgb: 0x7F8C98))
    static let keyword = NSColor.adaptive(light: NSColor(rgb: 0x9B2393), dark: NSColor(rgb: 0xFC5FA3))
    static let string = NSColor.adaptive(light: NSColor(rgb: 0xC41A16), dark: NSColor(rgb: 0xFC6A5D))
    static let number = NSColor.adaptive(light: NSColor(rgb: 0x1C00CF), dark: NSColor(rgb: 0xD0BF69))
    static let added = NSColor.systemGreen
    static let removed = NSColor.systemRed
    static let hunk = NSColor.systemBlue
    static let background = NSColor.textBackgroundColor
    static let gutter = NSColor.adaptive(light: NSColor(white: 0.965, alpha: 1), dark: NSColor(white: 0.16, alpha: 1))
}

enum Surface {
    /// Solid content: cards, code, lists. Never glass.
    static let card = Color(nsColor: .controlBackgroundColor)
    static let text = Color(nsColor: .textBackgroundColor)
    static let gutter = Color(nsColor: CodePalette.gutter)
    static let separator = Color(nsColor: .separatorColor)
}

extension View {
    /// A floating panel in Liquid Glass, faintly tinted with the character's colour.
    func glassPanel(tint: Color, corner: CGFloat) -> some View {
        glassEffect(.regular.tint(tint.opacity(0.07)), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    /// A solid content card on top of glass or a window.
    func solidCard(corner: CGFloat = 16, padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Surface.separator.opacity(0.5), lineWidth: 0.5))
    }

    /// The small capsule buttons used for shortcuts and row actions.
    func capsuleButton(tint: Color, prominent: Bool = false) -> some View {
        Group {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(tint)
    }
}

/// A section title in the style of System Settings and the Mail sidebar.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
