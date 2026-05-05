import SwiftUI
import RibbindKit

struct SettingsView: View {
    @EnvironmentObject private var catalog: Catalog

    var body: some View {
        TabView {
            AppShortcutsView(app: .word)
                .tabItem { Label("Word", systemImage: "doc.text") }

            AppShortcutsView(app: .powerpoint)
                .tabItem { Label("PowerPoint", systemImage: "rectangle.stack") }

            AppShortcutsView(app: .chrome)
                .tabItem { Label("Google Chrome", systemImage: "globe") }

            GeneralView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 780, minHeight: 560)
        .padding()
    }
}
