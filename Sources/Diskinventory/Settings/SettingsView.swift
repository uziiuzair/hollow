import AppKit
import DiskApp
import ServiceManagement
import SwiftUI

/// The drives Settings lists; the AppDelegate rewrites it when the registry changes.
@MainActor
final class SettingsDrives: ObservableObject {
    @Published var drives: [KnownDrive] = []
}

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var drives: SettingsDrives
    let setTint: (String, Int) -> Void
    let addFolders: () -> Void

    @State private var login = Self.loginToggle()
    @State private var selectedFolders: Set<String> = []

    var body: some View {
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $store.settings.menuBarStyle) {
                    Text("Ring and free space").tag(MenuBarStyle.ringAndNumber)
                    Text("Ring only").tag(MenuBarStyle.iconOnly)
                }
                Toggle("Launch at login", isOn: Binding(get: { login.isOn }, set: { setLaunchAtLogin($0) }))
                    .disabled(!login.isEnabled)
                if let note = login.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Warnings") {
                Stepper(value: $store.settings.lowPercent, in: 2...50) {
                    HStack { Text("Amber below"); Spacer(); Text("\(store.settings.lowPercent)% free").foregroundStyle(.secondary) }
                }
                Stepper(value: $store.settings.criticalPercent, in: 1...max(1, store.settings.lowPercent - 1)) {
                    HStack { Text("Red below"); Spacer(); Text("\(store.settings.criticalPercent)% free").foregroundStyle(.secondary) }
                }
            }
            Section("Drives") {
                ForEach(drives.drives, id: \.uuid) { drive in
                    LabeledContent(drive.name) {
                        HStack(spacing: 4) {
                            ForEach(0..<Palette.tints.count, id: \.self) { i in
                                Swatch(index: i, selected: drive.tintIndex == i) { setTint(drive.uuid, i) }
                            }
                        }
                    }
                }
            }
            Section("Skipped folders") {
                List(selection: $selectedFolders) {
                    ForEach(store.settings.excludedFolders, id: \.self) { path in
                        Text(path).lineLimit(1).truncationMode(.middle).help(path)
                    }
                }
                .frame(height: 84)
                .overlay {
                    if store.settings.excludedFolders.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Button(action: addFolders) { Image(systemName: "plus") }
                        .accessibilityLabel("Add a folder to skip")
                    Button(action: removeSelected) { Image(systemName: "minus") }
                        .accessibilityLabel("Stop skipping the selected folders")
                        .disabled(selectedFolders.isEmpty)
                    Spacer()
                }
                Text("Skipped folders don\u{2019}t appear in the map. Their space counts as Other.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { login = Self.loginToggle() }
    }

    private func removeSelected() {
        store.settings.excludedFolders.removeAll { selectedFolders.contains($0) }
        selectedFolders = []
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Diskinventory: could not change the login item: \(error)")
        }
        login = Self.loginToggle()
    }

    private static func loginToggle() -> LoginToggle {
        let status: LoginItemStatus
        switch SMAppService.mainApp.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .notFound
        default: status = .notRegistered
        }
        return LoginItem.toggle(status: status,
                                installed: LoginItem.shouldRegister(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory()))
    }
}

/// One of the eight drive colours; the chosen one carries a 2 pt outline in the label colour.
private struct Swatch: View {
    let index: Int
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            RoundedRectangle(cornerRadius: 4).fill(Palette.tints[index])
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay {
                    if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary, lineWidth: 2) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
