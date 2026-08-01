import SwiftUI

// MARK: - Appearance Preference

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        guard let raw = UserDefaults.standard.string(forKey: "openowl.appearance"),
              let value = AppAppearance(rawValue: raw) else { return .system }
        return value
    }

    static func apply(_ appearance: AppAppearance) {
        if appearance == .system {
            UserDefaults.standard.removeObject(forKey: "openowl.appearance")
        } else {
            UserDefaults.standard.set(appearance.rawValue, forKey: "openowl.appearance")
        }
        NSApp.appearance = appearance.nsAppearance
    }
}

// MARK: - Notification Sound

// MARK: - Settings View

struct SettingsView: View {
    @State private var appearance: AppAppearance = .current
    @State private var terminalTheme: String = GhosttyConfig.readOverride(key: "theme") ?? ""
    @State private var themeSearchQuery = ""
    @State private var showRestartHint = false

    private var availableThemes: [String] {
        let themes = Self.loadThemeList()
        if themeSearchQuery.isEmpty { return themes }
        return themes.filter { $0.localizedCaseInsensitiveContains(themeSearchQuery) }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Window Mode", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.label, systemImage: option.icon)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .onChange(of: appearance) { _, newValue in
                    AppAppearance.apply(newValue)
                }
            }

            Section("Terminal Theme") {
                TextField("Search themes...", text: $themeSearchQuery)
                    .textFieldStyle(.roundedBorder)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(availableThemes, id: \.self) { theme in
                            Button {
                                terminalTheme = theme
                            } label: {
                                Text(theme)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(terminalTheme == theme ? Color.accentColor : Color.clear)
                                    .foregroundStyle(terminalTheme == theme ? .white : .primary)
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 200)
                .background(AppPalette.surface)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .onChange(of: terminalTheme) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    GhosttyConfig.setOverride(key: "theme", value: newValue)
                    showRestartHint = true
                }

                if showRestartHint {
                    Label("Restart app to apply theme change", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
    }

    private static func loadThemeList() -> [String] {
        // Find themes directory in ghostty resources
        guard let resourcesDir = ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] else {
            return []
        }
        let themesDir = URL(fileURLWithPath: resourcesDir).appendingPathComponent("themes")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: themesDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        return files
            .map { $0.lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
