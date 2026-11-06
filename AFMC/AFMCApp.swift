import SwiftUI

@main
struct AFMCApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("afmc.theme") private var theme = "system"

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--theme"), index + 1 < args.count {
            UserDefaults.standard.set(args[index + 1], forKey: "afmc.theme")
        }
    }

    var body: some Scene {
        WindowGroup {
            SearchView()
                .environmentObject(model)
                .preferredColorScheme(colorScheme)
                .tint(AppPalette.accent)
        }
    }

    private var colorScheme: ColorScheme? {
        switch theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}

enum AppPalette {
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.00, green: 0.31, blue: 0.53, alpha: 1)
            : UIColor(red: 0.73, green: 0.06, blue: 0.28, alpha: 1)
    })
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let sidebar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.09, blue: 0.11, alpha: 1)
            : UIColor(red: 1.00, green: 0.94, blue: 0.96, alpha: 1)
    })
}
