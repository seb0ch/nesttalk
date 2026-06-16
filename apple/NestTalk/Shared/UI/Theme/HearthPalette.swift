import SwiftUI

/// Three-palette design system ported verbatim from the Claude Design
/// handoff bundle at `docs/design/nesttalk-bundle/project/nt-components.jsx`
/// constant `NT_THEMES`. Hex values and semantic names match byte-for-byte.
///
/// - `daylight` (Hearth) — light default, lavender-mist bg + royal-blue brand
/// - `nightlight` (Cocoa) — dark cozy deep-blue night
/// - `paper` (Linen) — soft neutral powder-blue + sage-green editorial
public struct HearthPalette: Sendable, Equatable {
    public let name: String
    public let bg: Color
    public let surface: Color
    public let surfaceAlt: Color
    public let ink: Color
    public let inkMuted: Color
    public let inkSoft: Color
    public let border: Color
    public let borderStrong: Color
    public let brand: Color
    public let brandSoft: Color
    public let accent: Color
    public let accentSoft: Color
    public let bubbleIn: Color
    public let bubbleInInk: Color
    public let bubbleOut: Color
    public let bubbleOutInk: Color
    public let success: Color
    public let warning: Color
    public let avatar1: Color
    public let avatar2: Color
    public let avatar3: Color
    public let avatar4: Color

    public static let daylight = HearthPalette(
        name:          "Daylight",
        bg:            Color(hex: 0xEEEEF7),
        surface:       Color(hex: 0xFFFFFF),
        surfaceAlt:    Color(hex: 0xE4E6F3),
        ink:           Color(hex: 0x0F1533),
        inkMuted:      Color(hex: 0x5C6590),
        inkSoft:       Color(hex: 0xA3A9C4),
        border:        Color(hex: 0x0F1533, alpha: 0.08),
        borderStrong:  Color(hex: 0x0F1533, alpha: 0.14),
        brand:         Color(hex: 0x2C47D6),  // royal blue — app icon body
        brandSoft:     Color(hex: 0xDCE3FB),
        accent:        Color(hex: 0x37B64A),  // fresh green — bubble
        accentSoft:    Color(hex: 0xD8F1DC),
        bubbleIn:      Color(hex: 0xFFFFFF),
        bubbleInInk:   Color(hex: 0x0F1533),
        bubbleOut:     Color(hex: 0x2C47D6),
        bubbleOutInk:  Color(hex: 0xFFFFFF),
        success:       Color(hex: 0x37B64A),
        warning:       Color(hex: 0xE09B2B),
        avatar1:       Color(hex: 0x2C47D6),
        avatar2:       Color(hex: 0x37B64A),
        avatar3:       Color(hex: 0x8B2E5E),  // mulberry (Grandma's sweater)
        avatar4:       Color(hex: 0x6C7AB8)
    )

    public static let nightlight = HearthPalette(
        name:          "Nightlight",
        bg:            Color(hex: 0x0C1030),
        surface:       Color(hex: 0x161B42),
        surfaceAlt:    Color(hex: 0x1F2554),
        ink:           Color(hex: 0xEDEFFB),
        inkMuted:      Color(hex: 0x9AA3CF),
        inkSoft:       Color(hex: 0x626AA0),
        border:        Color(hex: 0xEDEFFB, alpha: 0.08),
        borderStrong:  Color(hex: 0xEDEFFB, alpha: 0.14),
        brand:         Color(hex: 0x5E7BFF),
        brandSoft:     Color(hex: 0x2A3378),
        accent:        Color(hex: 0x5BC957),
        accentSoft:    Color(hex: 0x1F3A2B),
        bubbleIn:      Color(hex: 0x1F2554),
        bubbleInInk:   Color(hex: 0xEDEFFB),
        bubbleOut:     Color(hex: 0x5E7BFF),
        bubbleOutInk:  Color(hex: 0x0B1030),
        success:       Color(hex: 0x5BC957),
        warning:       Color(hex: 0xF0B757),
        avatar1:       Color(hex: 0x5E7BFF),
        avatar2:       Color(hex: 0x5BC957),
        avatar3:       Color(hex: 0xD96BA0),
        avatar4:       Color(hex: 0x8F98D4)
    )

    public static let paper = HearthPalette(
        name:          "Paper",
        bg:            Color(hex: 0xF1F3F8),
        surface:       Color(hex: 0xFFFFFF),
        surfaceAlt:    Color(hex: 0xE5E9F2),
        ink:           Color(hex: 0x18203B),
        inkMuted:      Color(hex: 0x5F6985),
        inkSoft:       Color(hex: 0xA6ADC2),
        border:        Color(hex: 0x18203B, alpha: 0.07),
        borderStrong:  Color(hex: 0x18203B, alpha: 0.14),
        brand:         Color(hex: 0x3A63C9),
        brandSoft:     Color(hex: 0xD9E2F5),
        accent:        Color(hex: 0x4E9E55),
        accentSoft:    Color(hex: 0xDBECDD),
        bubbleIn:      Color(hex: 0xFFFFFF),
        bubbleInInk:   Color(hex: 0x18203B),
        bubbleOut:     Color(hex: 0x3A63C9),
        bubbleOutInk:  Color(hex: 0xFFFFFF),
        success:       Color(hex: 0x4E9E55),
        warning:       Color(hex: 0xD58A32),
        avatar1:       Color(hex: 0x3A63C9),
        avatar2:       Color(hex: 0x4E9E55),
        avatar3:       Color(hex: 0x8B2E5E),
        avatar4:       Color(hex: 0x7381A5)
    )
}

// MARK: - Environment injection

private struct HearthPaletteKey: EnvironmentKey {
    static let defaultValue: HearthPalette = .daylight
}

public extension EnvironmentValues {
    var hearth: HearthPalette {
        get { self[HearthPaletteKey.self] }
        set { self[HearthPaletteKey.self] = newValue }
    }
}

public extension View {
    /// Install the given palette for this subtree.
    func hearthTheme(_ palette: HearthPalette) -> some View {
        environment(\.hearth, palette)
    }
}

// MARK: - Color hex helper

extension Color {
    /// Construct an opaque Color from a 0xRRGGBB int; optionally with alpha.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
