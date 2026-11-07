// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

/// Réglage caché basé sur `defaults` (inspiré d'OnyX « Paramètres » et TinkerTool).
struct Tweak: Identifiable {
    var id: String { domain + "." + key }
    let section: String
    let title: String
    let domain: String
    let key: String
    let type: String        // bool, float, int, string
    let on: String
    let off: String?        // nil : retour à la valeur par défaut (defaults delete)
    let restart: String?    // processus à relancer pour appliquer
    var enabled = false

    static let all: [Tweak] = [
        Tweak(section: "Finder", title: String(localized: "Afficher les fichiers cachés"), domain: "com.apple.finder", key: "AppleShowAllFiles", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Afficher toutes les extensions de fichiers"), domain: "NSGlobalDomain", key: "AppleShowAllExtensions", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Afficher la barre du chemin"), domain: "com.apple.finder", key: "ShowPathbar", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Afficher la barre d'état"), domain: "com.apple.finder", key: "ShowStatusBar", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Chemin complet dans le titre des fenêtres"), domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Dossiers en premier lors du tri"), domain: "com.apple.finder", key: "_FXSortFoldersFirst", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Pas d'alerte en changeant une extension"), domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", type: "bool", on: "false", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Pas de fichiers .DS_Store sur les disques réseau"), domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", type: "bool", on: "true", off: nil, restart: "Finder"),
        Tweak(section: "Finder", title: String(localized: "Pas de fichiers .DS_Store sur les clés USB"), domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", type: "bool", on: "true", off: nil, restart: "Finder"),

        Tweak(section: "Dock", title: String(localized: "Masquer automatiquement le Dock"), domain: "com.apple.dock", key: "autohide", type: "bool", on: "true", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Apparition instantanée (sans délai)"), domain: "com.apple.dock", key: "autohide-delay", type: "float", on: "0", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Animation d'apparition rapide"), domain: "com.apple.dock", key: "autohide-time-modifier", type: "float", on: "0.15", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Icônes translucides pour les apps masquées"), domain: "com.apple.dock", key: "showhidden", type: "bool", on: "true", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Ne pas afficher les apps récentes"), domain: "com.apple.dock", key: "show-recents", type: "bool", on: "false", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Réduire les fenêtres dans l'icône de l'app"), domain: "com.apple.dock", key: "minimize-to-application", type: "bool", on: "true", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "N'afficher que les apps ouvertes"), domain: "com.apple.dock", key: "static-only", type: "bool", on: "true", off: nil, restart: "Dock"),
        Tweak(section: "Dock", title: String(localized: "Ne pas réorganiser les Spaces automatiquement"), domain: "com.apple.dock", key: "mru-spaces", type: "bool", on: "false", off: nil, restart: "Dock"),

        Tweak(section: String(localized: "Captures d'écran"), title: String(localized: "Supprimer l'ombre des fenêtres capturées"), domain: "com.apple.screencapture", key: "disable-shadow", type: "bool", on: "true", off: nil, restart: "SystemUIServer"),
        Tweak(section: String(localized: "Captures d'écran"), title: String(localized: "Enregistrer en JPEG (plus léger que PNG)"), domain: "com.apple.screencapture", key: "type", type: "string", on: "jpg", off: nil, restart: "SystemUIServer"),
        Tweak(section: String(localized: "Captures d'écran"), title: String(localized: "Ne pas afficher la vignette flottante"), domain: "com.apple.screencapture", key: "show-thumbnail", type: "bool", on: "false", off: nil, restart: "SystemUIServer"),

        Tweak(section: String(localized: "Système"), title: String(localized: "Fenêtres d'enregistrement développées par défaut"), domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", type: "bool", on: "true", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "Fenêtres d'impression développées par défaut"), domain: "NSGlobalDomain", key: "PMPrintingExpandedStateForPrint", type: "bool", on: "true", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "Enregistrer sur le Mac plutôt que dans iCloud"), domain: "NSGlobalDomain", key: "NSDocumentSaveNewDocumentsToCloud", type: "bool", on: "false", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "Désactiver la correction orthographique automatique"), domain: "NSGlobalDomain", key: "NSAutomaticSpellingCorrectionEnabled", type: "bool", on: "false", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "Désactiver les animations d'ouverture de fenêtres"), domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", type: "bool", on: "false", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "TextEdit : nouveaux documents en texte brut"), domain: "com.apple.TextEdit", key: "RichText", type: "bool", on: "false", off: nil, restart: nil),
        Tweak(section: String(localized: "Système"), title: String(localized: "Time Machine : ne pas proposer les nouveaux disques"), domain: "com.apple.TimeMachine", key: "DoNotOfferNewDisksForBackup", type: "bool", on: "true", off: nil, restart: nil),
    ]

    func readEnabled() -> Bool {
        let r = Shell.exec("/usr/bin/defaults", ["read", domain, key])
        guard r.ok else { return false }
        func norm(_ s: String) -> String {
            switch s.lowercased() {
            case "true", "yes", "1": return "1"
            case "false", "no", "0": return "0"
            default: return Double(s).map { String($0) } ?? s
            }
        }
        return norm(r.output) == norm(on)
    }

    func apply(_ enable: Bool) {
        if enable {
            Shell.exec("/usr/bin/defaults", ["write", domain, key, "-\(type)", on])
        } else if let off {
            Shell.exec("/usr/bin/defaults", ["write", domain, key, "-\(type)", off])
        } else {
            Shell.exec("/usr/bin/defaults", ["delete", domain, key])
        }
        if let restart { Shell.exec("/usr/bin/killall", [restart]) }
    }
}

struct HiddenUtility: Identifiable {
    var id: String { name }
    let name: String
    let url: URL

    static var available: [HiddenUtility] {
        let core = "/System/Library/CoreServices/Applications/", utils = "/System/Applications/Utilities/"
        let candidates: [(String, [String])] = [
            (String(localized: "Diagnostic sans fil"), [core + "Wireless Diagnostics.app"]),
            (String(localized: "Utilitaire d'annuaire"), [core + "Directory Utility.app"]),
            (String(localized: "Partage d'écran"), [core + "Screen Sharing.app", utils + "Screen Sharing.app"]),
            (String(localized: "Visualiseur de tickets"), [core + "Ticket Viewer.app"]),
            (String(localized: "Utilitaire d'archive"), [core + "Archive Utility.app"]),
            (String(localized: "Assistant d'évaluation"), [core + "Feedback Assistant.app", "/System/Library/CoreServices/Applications/Feedback Assistant.app"]),
            (String(localized: "Trousseaux d'accès"), [core + "Keychain Access.app", utils + "Keychain Access.app"]),
            (String(localized: "Informations système"), [utils + "System Information.app"]),
            ("Console", [utils + "Console.app"]),
            (String(localized: "Utilitaire de disque"), [utils + "Disk Utility.app"]),
            (String(localized: "Utilitaire ColorSync"), [utils + "ColorSync Utility.app"]),
            (String(localized: "Moniteur d'activité"), [utils + "Activity Monitor.app"]),
        ]
        return candidates.compactMap { name, paths in
            paths.first { FileManager.default.fileExists(atPath: $0) }.map { HiddenUtility(name: name, url: URL(fileURLWithPath: $0)) }
        }
    }
}

final class TweaksModel: ObservableObject {
    @Published var tweaks = Tweak.all
    @Published var screenshotFolder = ""
    @Published var loaded = false
    let utilities = HiddenUtility.available

    var sections: [String] { tweaks.map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let states = Tweak.all.map { $0.readEnabled() }
            let loc = Shell.exec("/usr/bin/defaults", ["read", "com.apple.screencapture", "location"])
            DispatchQueue.main.async {
                for i in self.tweaks.indices { self.tweaks[i].enabled = states[i] }
                self.screenshotFolder = loc.ok ? loc.output : "~/Desktop"
                self.loaded = true
            }
        }
    }

    func set(_ t: Tweak, _ v: Bool) {
        guard let i = tweaks.firstIndex(where: { $0.id == t.id }) else { return }
        tweaks[i].enabled = v
        DispatchQueue.global(qos: .userInitiated).async { t.apply(v) }
    }

    func chooseScreenshotFolder() {
        guard let u = FS.chooseFolder(start: FS.home.appendingPathComponent("Desktop")) else { return }
        Shell.exec("/usr/bin/defaults", ["write", "com.apple.screencapture", "location", u.path])
        Shell.exec("/usr/bin/killall", ["SystemUIServer"])
        screenshotFolder = FS.displayPath(u)
    }

    func resetAll() {
        DispatchQueue.global(qos: .userInitiated).async {
            for t in Tweak.all { Shell.exec("/usr/bin/defaults", ["delete", t.domain, t.key]) }
            for p in Set(Tweak.all.compactMap(\.restart)) { Shell.exec("/usr/bin/killall", [p]) }
            DispatchQueue.main.async { self.load() }
        }
    }
}

struct TweaksView: View {
    @ObservedObject var model: TweaksModel
    @AppStorage("menuBarMonitor") private var menuBarMonitor = true
    @Local private var confirmReset = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Réglages cachés"), subtitle: String(localized: "Options avancées de macOS, sans Terminal"),
                       icon: "slider.horizontal.3", color: .yellow) {
                Button("Tout rétablir par défaut…") { confirmReset = true }
            }
            Form {
                Section("Boîte à outils") {
                    Toggle("Moniteur système dans la barre des menus", isOn: $menuBarMonitor)
                    LanguePicker()
                }
                ForEach(model.sections, id: \.self) { s in
                    Section(s) {
                        ForEach(model.tweaks.filter { $0.section == s }) { t in
                            Toggle(t.title, isOn: Binding(get: { t.enabled }, set: { model.set(t, $0) }))
                                .help("defaults write \(t.domain) \(t.key) -\(t.type) \(t.on)")
                        }
                        if s == String(localized: "Captures d'écran") {
                            HStack {
                                Text("Dossier des captures : \(model.screenshotFolder)")
                                Spacer()
                                Button("Changer…") { model.chooseScreenshotFolder() }
                            }
                        }
                    }
                }
                Section("Utilitaires système cachés") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(model.utilities) { u in
                            Button { NSWorkspace.shared.open(u.url) } label: {
                                VStack(spacing: 6) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: u.url.path)).resizable().frame(width: 40, height: 40)
                                    Text(u.name).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .formStyle(.grouped)
            .disabled(!model.loaded)
        }
        .onAppear { if !model.loaded { model.load() } }
        .confirmationDialog("Rétablir tous ces réglages par défaut ?", isPresented: $confirmReset) {
            Button("Rétablir", role: .destructive) { model.resetAll() }
        } message: { Text("Le Finder, le Dock et la barre des menus seront relancés.") }
    }
}
