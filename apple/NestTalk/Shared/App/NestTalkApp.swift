import SwiftUI

@main
struct NestTalkApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("nt.palette") private var paletteChoice: String = "auto"
    @Environment(\.colorScheme) private var systemScheme

    var body: some Scene {
        WindowGroup {
            AppRouter()
                .environmentObject(appState)
                .hearthTheme(resolvedPalette)
                .background(resolvedPalette.bg.ignoresSafeArea())
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        // Onboarding (welcome / paste-invite / error) has no intrinsic size,
        // so without this the window opens oversized. Open compact & portrait;
        // once connected, macOSConnectedShell's minWidth:900 grows the window
        // to the chat layout.
        .defaultSize(width: 480, height: 680)
#endif
    }

    private var resolvedPalette: HearthPalette {
        switch paletteChoice {
        case "daylight":   return .daylight
        case "nightlight": return .nightlight
        case "paper":      return .paper
        default:
            return systemScheme == .dark ? .nightlight : .daylight
        }
    }
}
