// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

enum LaunchScope: String {
    case user = "Utilisateur"
    case agent = "Tous les utilisateurs"
    case daemon = "Système (daemon)"

    var activeDir: URL {
        switch self {
        case .user: FS.home.appendingPathComponent("Library/LaunchAgents")
        case .agent: URL(fileURLWithPath: "/Library/LaunchAgents")
        case .daemon: URL(fileURLWithPath: "/Library/LaunchDaemons")
        }
    }

    /// Les éléments désactivés sont déplacés ici (et peuvent être réactivés).
    var disabledDir: URL {
        switch self {
        case .user: FS.home.appendingPathComponent("Library/Application Support/BoiteAOutils/Désactivés/LaunchAgents")
        case .agent: URL(fileURLWithPath: "/Library/Application Support/BoiteAOutils/Désactivés/LaunchAgents")
        case .daemon: URL(fileURLWithPath: "/Library/Application Support/BoiteAOutils/Désactivés/LaunchDaemons")
        }
    }

    var domain: String { self == .daemon ? "system" : "gui/\(getuid())" }
}

struct LaunchItem: Identifiable {
    var id: String { url.path }
    let url: URL
    let label: String
    let program: String
    let scope: LaunchScope
    let enabled: Bool
    var isApple: Bool { label.hasPrefix("com.apple.") }
}

final class StartupModel: ObservableObject {
    @Published var items: [LaunchItem] = []
    @Published var loginItems: [String] = []
    @Published var loginItemsLoaded = false
    @Published var message: String?
    @Published var hideApple = true

    static func disabledPath(for file: String) -> URL { LaunchScope.user.disabledDir.appendingPathComponent(file) }

    var visible: [LaunchItem] { items.filter { !hideApple || !$0.isApple } }

    func load() {
        var list: [LaunchItem] = []
        for scope in [LaunchScope.user, .agent, .daemon] {
            for (dir, enabled) in [(scope.activeDir, true), (scope.disabledDir, false)] {
                for f in FS.children(dir) where f.pathExtension == "plist" {
                    let d = NSDictionary(contentsOf: f) as? [String: Any]
                    let program = (d?["Program"] as? String) ?? (d?["ProgramArguments"] as? [String])?.first ?? ""
                    list.append(LaunchItem(url: f, label: d?["Label"] as? String ?? f.deletingPathExtension().lastPathComponent,
                                           program: program, scope: scope, enabled: enabled))
                }
            }
        }
        items = list.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    func toggle(_ item: LaunchItem) {
        let name = item.url.lastPathComponent
        let target = (item.enabled ? item.scope.disabledDir : item.scope.activeDir).appendingPathComponent(name)
        let q = Shell.quote
        let cmd: String
        if item.enabled {
            cmd = "launchctl bootout \(item.scope.domain) \(q(item.url.path)) 2>/dev/null; mkdir -p \(q(item.scope.disabledDir.path)) && mv \(q(item.url.path)) \(q(target.path))"
        } else {
            cmd = "mkdir -p \(q(item.scope.activeDir.path)) && mv \(q(item.url.path)) \(q(target.path)) && (launchctl bootstrap \(item.scope.domain) \(q(target.path)) 2>/dev/null || true)"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = item.scope == .user ? Shell.sh(cmd) : Shell.admin(cmd)
            DispatchQueue.main.async {
                self.message = r.ok ? "« \(item.label) » \(item.enabled ? "désactivé" : "réactivé")."
                                    : "Échec : \(r.output)"
                self.load()
            }
        }
    }

    func loadLoginItems() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.appleScript("tell application \"System Events\" to get the name of every login item")
            let names = r.ok && !r.output.isEmpty ? r.output.components(separatedBy: ", ") : []
            DispatchQueue.main.async {
                self.loginItems = names
                self.loginItemsLoaded = true
                if !r.ok { self.message = "Accès refusé à System Events : autorisez-le dans Réglages > Confidentialité > Automatisation." }
            }
        }
    }

    func removeLoginItem(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            Shell.appleScript("tell application \"System Events\" to delete login item \"\(Shell.appleScriptEscape(name))\"")
            DispatchQueue.main.async { self.loadLoginItems() }
        }
    }
}

struct StartupView: View {
    @ObservedObject var model: StartupModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Démarrage", subtitle: "Applications et services lancés automatiquement",
                       icon: "power", color: .green) {
                Button { model.load(); model.loadLoginItems() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            }
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                Section {
                    if model.loginItems.isEmpty {
                        Text(model.loginItemsLoaded ? "Aucun élément d'ouverture classique." : "Chargement…").foregroundStyle(.secondary)
                    }
                    ForEach(model.loginItems, id: \.self) { name in
                        HStack {
                            Image(systemName: "app.badge").foregroundStyle(.green)
                            Text(name)
                            Spacer()
                            Button("Retirer") { model.removeLoginItem(name) }
                        }
                    }
                    Button("Ouvrir les réglages « Ouverture » (éléments en arrière-plan)…") {
                        Permissions.openSettings("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                    }.buttonStyle(.link)
                } header: {
                    Text("Ouverture à la connexion")
                }

                Section {
                    ForEach(model.visible) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.scope == .daemon ? "gearshape.2.fill" : "bolt.horizontal.circle.fill")
                                .foregroundStyle(item.enabled ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label).lineLimit(1)
                                Text("\(item.scope.rawValue) · \(item.program.isEmpty ? "—" : item.program)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button { FS.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            Toggle("", isOn: Binding(get: { item.enabled }, set: { _ in model.toggle(item) }))
                                .toggleStyle(.switch).labelsHidden()
                        }
                    }
                } header: {
                    HStack {
                        Text("Agents et services de lancement")
                        Spacer()
                        Toggle("Masquer les éléments Apple", isOn: $model.hideApple).toggleStyle(.checkbox)
                    }
                } footer: {
                    Text("Désactiver un service le déplace dans « Application Support/BoiteAOutils/Désactivés » : il peut être réactivé à tout moment. Les services système demandent le mot de passe administrateur.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .onAppear {
            model.load()
            if !model.loginItemsLoaded { model.loadLoginItems() }
        }
    }
}
