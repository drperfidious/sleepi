import AppIntents
struct SleepiShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenTonightIntent(), phrases: ["Open tonight in \(.applicationName)", "Get ready for bed with \(.applicationName)"], shortTitle: "Open Tonight", systemImageName: "moon.stars")
    }
}
