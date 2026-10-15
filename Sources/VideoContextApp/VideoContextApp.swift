import SwiftUI

@main
struct VideoContextApp: App {
    @NSApplicationDelegateAdaptor(DiagnosticsAppDelegate.self) private var appDelegate
    @State private var model: AppModel = {
        if CommandLine.arguments.contains("--ui-fixture") {
            return AppModel(libraryRoot: FileManager.default.temporaryDirectory.appending(path: "VideoContextUI-\(UUID())"), isUIFixture: true)
        }
        return AppModel()
    }()

    var body: some Scene {
        WindowGroup("Video Context") {
            LibraryView(model: model)
                .task {
                    appDelegate.diagnostics = model.diagnostics
                    appDelegate.agentConnections = model.agentConnections
                }
                .frame(minWidth: 1_080, minHeight: 720)
                .frame(width: model.isUIFixture && CommandLine.arguments.contains("--ui-minimum") ? 1080 : nil,
                       height: model.isUIFixture && CommandLine.arguments.contains("--ui-minimum") ? 720 : nil)
                .tint(.indigo)
                .preferredColorScheme(CommandLine.arguments.contains("--ui-light") ? .light : CommandLine.arguments.contains("--ui-dark") ? .dark : nil)
        }
        .windowResizability(model.isUIFixture && CommandLine.arguments.contains("--ui-minimum") ? .contentSize : .contentMinSize)
        .defaultSize(width: 1360, height: 900)

        Settings {
            SettingsView(model: model)
                .frame(width: 680, height: 650)
                .tint(.indigo)
        }
    }
}
