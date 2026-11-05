// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct PrivacyItem: Identifiable {
    let id = UUID()
    let group: String
    let label: String
    let detail: String
    let paths: [URL]
    let bundleIDs: [String]
    var size: Int64 = 0
    var selected: Bool
}

/// Traces de navigation et d'activité (inspiré de CCleaner / CleanMyMac « Confidentialité »).
final class PrivacyModel: ObservableObject {
    @Published var items: [PrivacyItem] = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var cleaning = false
    @Published var message: String?

    var groups: [String] { items.map(\.group).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var selected: [PrivacyItem] { items.filter(\.selected) }

    /// Navigateurs ouverts concernés par la sélection : ils doivent être fermés avant le nettoyage.
    var runningApps: [NSRunningApplication] {
        Set(selected.flatMap(\.bundleIDs)).flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
    }

    private static let chromium: [(name: String, id: String, support: String, cache: String)] = [
        ("Google Chrome", "com.google.Chrome", "Google/Chrome", "Google/Chrome"),
        ("Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser", "BraveSoftware/Brave-Browser"),
        ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge", "Microsoft Edge"),
        ("Arc", "company.thebrowser.Browser", "Arc/User Data", "Arc"),
        ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi", "Vivaldi"),
        ("Opera", "com.operasoftware.Opera", "com.operasoftware.Opera", "com.operasoftware.Opera"),
    ]

    func scan() {
        scanning = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let L = FS.home.appendingPathComponent("Library")
            var list: [PrivacyItem] = []
            func add(_ group: String, _ label: String, _ detail: String, _ paths: [URL], _ ids: [String], _ selected: Bool) {
                let existing = paths.filter(FS.exists)
                guard !existing.isEmpty else { return }
                list.append(PrivacyItem(group: group, label: label, detail: detail, paths: existing, bundleIDs: ids,
                                        size: existing.reduce(0) { $0 + FS.size(of: $1) }, selected: selected))
            }

            // Safari
            let safariData = L.appendingPathComponent("Containers/com.apple.Safari/Data/Library")
            add("Safari", "Cache", "Pages et images mises en cache.",
                [L.appendingPathComponent("Caches/com.apple.Safari"), safariData.appendingPathComponent("Caches")], ["com.apple.Safari"], true)
            add("Safari", "Historique de navigation", "Sites visités et dernière session.",
                ["History.db", "History.db-wal", "History.db-shm", "LastSession.plist"].map { L.appendingPathComponent("Safari/\($0)") },
                ["com.apple.Safari"], false)
            add("Safari", "Cookies", "Vous serez déconnecté des sites web.",
                [L.appendingPathComponent("Cookies/Cookies.binarycookies"), safariData.appendingPathComponent("Cookies/Cookies.binarycookies")],
                ["com.apple.Safari"], false)

            // Navigateurs Chromium
            for b in Self.chromium {
                let base = L.appendingPathComponent("Application Support/\(b.support)")
                let profiles = FS.children(base).filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile ") }
                guard !profiles.isEmpty else { continue }
                func files(_ names: [String]) -> [URL] { profiles.flatMap { p in names.map { p.appendingPathComponent($0) } } }
                add(b.name, "Cache", "Pages, scripts et images mis en cache.",
                    files(["Cache", "Code Cache", "GPUCache", "Service Worker/CacheStorage"]) + [L.appendingPathComponent("Caches/\(b.cache)")],
                    [b.id], true)
                add(b.name, "Historique de navigation", "Sites visités, sites fréquents, raccourcis.",
                    files(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal"]),
                    [b.id], false)
                add(b.name, "Cookies", "Vous serez déconnecté des sites web.",
                    files(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]), [b.id], false)
            }

            // Firefox (l'historique partage sa base avec les favoris : on ne touche qu'aux formulaires)
            let ffProfiles = FS.children(L.appendingPathComponent("Application Support/Firefox/Profiles")).filter { FS.isDirectory($0) }
            if !ffProfiles.isEmpty {
                func ff(_ names: [String]) -> [URL] { ffProfiles.flatMap { p in names.map { p.appendingPathComponent($0) } } }
                add("Firefox", "Cache", "Pages et images mises en cache.", [L.appendingPathComponent("Caches/Firefox")], ["org.mozilla.firefox"], true)
                add("Firefox", "Cookies", "Vous serez déconnecté des sites web.",
                    ff(["cookies.sqlite", "cookies.sqlite-wal", "cookies.sqlite-shm"]), ["org.mozilla.firefox"], false)
                add("Firefox", "Saisies de formulaires", "Texte mémorisé dans les champs de formulaire.",
                    ff(["formhistory.sqlite"]), ["org.mozilla.firefox"], false)
            }

            // Système
            let sfl = L.appendingPathComponent("Application Support/com.apple.sharedfilelist")
            add("Activité sur le Mac", "Documents et applications récents", "Listes « Éléments récents » du menu Pomme et des apps.",
                FS.children(sfl).filter { $0.lastPathComponent.contains("Recent") }, [], false)
            add("Activité sur le Mac", "Historique du Terminal", "Commandes tapées dans zsh, bash, Python et Node.",
                [".zsh_history", ".bash_history", ".zsh_sessions", ".python_history", ".node_repl_history", ".lesshst"]
                    .map { FS.home.appendingPathComponent($0) }, ["com.apple.Terminal"], false)
            add("Activité sur le Mac", "Miniatures Coup d'œil", "Aperçus des fichiers déjà consultés.",
                [URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent().appendingPathComponent("C/com.apple.QuickLook.thumbnailcache")],
                [], false)

            DispatchQueue.main.async {
                self.items = list
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    func clean(quitApps: Bool) {
        let work = selected
        let apps = runningApps
        cleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            if quitApps && !apps.isEmpty {
                apps.forEach { $0.terminate() }
                for _ in 0..<50 where apps.contains(where: { !$0.isTerminated }) { Thread.sleep(forTimeInterval: 0.1) }
            }
            var freed: Int64 = 0
            for item in work {
                for p in item.paths { try? FS.remove(p, permanently: true) }
                freed += item.size
            }
            if work.contains(where: { $0.label.contains("récents") }) { Shell.exec("/usr/bin/killall", ["sharedfilelistd"]) }
            if work.contains(where: { $0.label.contains("Coup d'œil") }) { Shell.exec("/usr/bin/qlmanage", ["-r", "cache"]) }
            DispatchQueue.main.async {
                self.cleaning = false
                self.message = "Traces effacées (\(formatBytes(freed)))."
                self.scan()
            }
        }
    }
}

struct PrivacyView: View {
    @ObservedObject var model: PrivacyModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Confidentialité", subtitle: "Effacez l'historique, les cookies et les traces d'activité",
                       icon: "hand.raised.fill", color: .blue) {
                if model.scannedOnce && !model.scanning {
                    Button { model.scan() } label: { Label("Réanalyser", systemImage: "arrow.clockwise") }
                }
            }
            FullDiskAccessBanner()
            if let m = model.message {
                Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .padding(.horizontal, 24).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.scanning || model.cleaning {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "hand.raised", title: "Protéger votre vie privée",
                           message: "Safari, Chrome, Brave, Edge, Arc, Firefox… ainsi que les documents récents et l'historique du Terminal.",
                           actionTitle: "Analyser") { model.scan() }
            } else if model.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Aucune trace trouvée", message: "Rien à effacer.")
            } else {
                List {
                    ForEach(model.groups, id: \.self) { g in
                        Section(g) {
                            ForEach($model.items) { $item in
                                if item.group == g {
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.label)
                                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                BottomBar {
                    let running = model.runningApps.compactMap(\.localizedName)
                    if !running.isEmpty {
                        Label("À fermer : " + running.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Effacer les traces") { confirm = true }
                        .buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Effacer \(model.selected.count) élément(s) ?", isPresented: $confirm) {
            if model.runningApps.isEmpty {
                Button("Effacer", role: .destructive) { model.clean(quitApps: false) }
            } else {
                Button("Quitter les apps et effacer", role: .destructive) { model.clean(quitApps: true) }
            }
        } message: {
            Text("Suppression définitive. Les navigateurs ouverts doivent être quittés pour que l'effacement soit pris en compte.")
        }
    }
}
