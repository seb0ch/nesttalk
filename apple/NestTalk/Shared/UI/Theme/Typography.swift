import SwiftUI

/// Hearth typography helpers. Fonts are in-bundle (see
/// `NestTalk/Shared/Resources/Fonts/`) and registered via Info.plist
/// `UIAppFonts` (iOS) / `ATSApplicationFontsPath` (macOS).
///
/// Families (taken directly from the design bundle at
/// `docs/design/nesttalk-bundle/project/nt-components.jsx`):
///
///   * **Fraunces** — serif; headlines and names ("a letter from home")
///   * **Inter**    — sans-serif; UI chrome and body
///   * **JetBrains Mono** — debug / small monospace tags
///
/// The bundled TTFs are variable fonts; SwiftUI picks the nearest axis
/// value by Weight. Optical-size axis is resolved automatically by the
/// text rendering pipeline on Apple platforms.
public enum Typography {

    public static let frauncesFamily = "Fraunces"
    public static let interFamily    = "Inter"
    public static let monoFamily     = "JetBrains Mono"

    public static func fraunces(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .custom(frauncesFamily, size: size).weight(weight)
    }

    public static func inter(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(interFamily, size: size).weight(weight)
    }

    public static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(monoFamily, size: size).weight(weight)
    }
}

public extension View {
    /// Apply Fraunces at `size`/`weight`.
    func frauncesFont(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(Typography.fraunces(size: size, weight: weight))
    }

    /// Apply Inter at `size`/`weight`.
    func interFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(Typography.inter(size: size, weight: weight))
    }

    /// Apply JetBrains Mono at `size`/`weight`.
    func monoFont(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        font(Typography.mono(size: size, weight: weight))
    }
}
