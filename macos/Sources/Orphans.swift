// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct OrphanItem: Identifiable {
    let id = UUID()
    let url: URL
    let bundleID: String
    let size: Int64
    /// Un autre logiciel du même éditeur est encore installé : à vérifier avant suppression.
    let vendorInstalled: Bool
    var selected: Bool
}

/// Restes d'applications déjà supprimées (inspiré de Pearcleaner).
final class OrphansModel: ObservableObject {
    @Published var items: [OrphanItem] = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var message: String?

    static let dirs = ["Application Support", "Caches", "Containers", "Preferences", "Saved Application State",
                       "HTTPStorages", "WebKit", "Logs", "Application Scripts", "Cookies"]
    private static let suffixes = [".plist", ".savedState", ".binarycookies"]
    private static let skippedPrefixes = ["com.apple.", "group.", "groups.", "systemgroup.", "com.boiteaoutils.", "org.cups.",
                                          // bibliothèques partagées par de nombreuses apps
                                          "com.plausiblelabs.", "org.sparkle-project.", "io.sentry.", "com.crashlytics."]
    /// Préfixe d'équipe développeur (ex. « UBF8T346G9. ») ou « maccatalyst. » devant l'identifiant.
    private static let idPrefix = try! NSRegularExpression(pattern: #"^([A-Z0-9]{10}\.|maccatalyst\.)"#)

    var selected: [OrphanItem] { items.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }

    func scan() {
        scanning = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.main.async { self.status = String(localized: "Inventaire des applications installées…") }
            let ids = Self.installedBundleIDs()
            let vendors = Set(ids.map(Self.vendor))
            let ignored = IgnoreList.get("orphans")
            let pattern = try! NSRegularExpression(pattern: #"^[a-z][a-z0-9-]*\.[a-z0-9-]+\.[a-z0-9._-]+$"#, options: [.caseInsensitive])

            var found: [OrphanItem] = []
            for d in Self.dirs {
                DispatchQueue.main.async { self.status = String(localized: "Analyse de ~/Library/\(d)…") }
                for f in FS.children(FS.home.appendingPathComponent("Library/\(d)")) where !ignored.contains(f.path) {
                    var name = f.lastPathComponent
                    for s in Self.suffixes where name.hasSuffix(s) { name = String(name.dropLast(s.count)) }
                    let stripped = Self.idPrefix.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: "")
                    let cand = stripped.lowercased()
                    guard pattern.firstMatch(in: cand, range: NSRange(cand.startIndex..., in: cand)) != nil,
                          !Self.skippedPrefixes.contains(where: cand.hasPrefix), !cand.contains("com.apple."),
                          !Self.isInstalled(cand, ids) else { continue }
                    let vendorOK = vendors.contains(Self.vendor(cand))
                    found.append(OrphanItem(url: f, bundleID: name, size: FS.size(of: f), vendorInstalled: vendorOK, selected: !vendorOK))
                }
            }
            found.sort { $0.size > $1.size }
            DispatchQueue.main.async {
                self.items = found
                self.scanning = false
                self.scannedOnce = true
            }
        }
    }

    private static func vendor(_ id: String) -> String { id.split(separator: ".").prefix(2).joined(separator: ".") }

    private static func isInstalled(_ cand: String, _ ids: Set<String>) -> Bool {
        if ids.contains(cand) { return true }
        // ex. com.editeur.app.helper (reste d'une app installée) ou com.editeur (préfixe d'une app installée)
        return ids.contains { cand.hasPrefix($0 + ".") || $0.hasPrefix(cand + ".") }
    }

    /// Identifiants de toutes les apps du Mac (Spotlight + dossiers usuels + apps ouvertes).
    static func installedBundleIDs() -> Set<String> {
        var paths = Set(Shell.exec("/usr/bin/mdfind", ["kMDItemContentType == 'com.apple.application-bundle'"])
            .output.split(separator: "\n").map(String.init))
        for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    FS.home.appendingPathComponent("Applications").path, "/System/Library/CoreServices"] {
            for u in FS.children(URL(fileURLWithPath: dir)) where u.pathExtension == "app" { paths.insert(u.path) }
        }
        var ids = Set<String>()
        for p in paths {
            if let id = FS.appInfo(URL(fileURLWithPath: p))?["CFBundleIdentifier"] as? String { ids.insert(id.lowercased()) }
        }
        for app in NSWorkspace.shared.runningApplications { if let id = app.bundleIdentifier { ids.insert(id.lowercased()) } }
        return ids
    }

    func ignore(_ item: OrphanItem) {
        IgnoreList.add("orphans", item.url)
        items.removeAll { $0.id == item.id }
    }

    func trashSelected() {
        let failed = Set(FS.trash(selected.map(\.url), adminFallback: false))
        let count = selected.count - failed.count
        items.removeAll { $0.selected && !failed.contains($0.url) }
        message = String(localized: "\(count) élément(s) placés dans la corbeille.") + (failed.isEmpty ? "" : String(localized: " \(failed.count) échec(s)."))
    }
}

struct OrphansView: View {
    @ObservedObject var model: OrphansModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Restes orphelins"), subtitle: String(localized: "Fichiers laissés par des applications déjà supprimées"),
                       icon: "puzzlepiece.extension.fill", color: .brown) {
                if model.scannedOnce && !model.scanning {
                    Button { model.scan() } label: { Label("Réanalyser", systemImage: "arrow.clockwise") }
                }
            }
            FullDiskAccessBanner()
            if let m = model.message {
                Text(m).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.scanning {
                VStack(spacing: 10) { ProgressView(); Text(model.status).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "puzzlepiece.extension", title: String(localized: "Rechercher les restes orphelins"),
                           message: String(localized: "Compare les préférences, caches et conteneurs de votre Bibliothèque avec les applications réellement installées."),
                           actionTitle: String(localized: "Analyser")) { model.scan() }
            } else if model.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: String(localized: "Aucun reste trouvé"), message: String(localized: "Aucun fichier d'application désinstallée détecté."))
            } else {
                List($model.items) { $item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.bundleID).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(FS.displayPath(item.url.deletingLastPathComponent()))
                                if item.vendorInstalled {
                                    Text("· éditeur encore installé, à vérifier").foregroundStyle(.orange)
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                        Button { FS.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Afficher dans le Finder") { FS.reveal([item.url]) }
                        Button("Toujours ignorer cet élément") { model.ignore(item) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                BottomBar {
                    VStack(alignment: .leading) {
                        Text("\(model.items.count) éléments · sélection : \(formatBytes(model.selectedSize))").font(.headline)
                        Text("Les éléments d'un éditeur encore présent ne sont pas cochés par défaut.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Tout sélectionner") { for i in model.items.indices { model.items[i].selected = true } }
                    Button("Tout désélectionner") { for i in model.items.indices { model.items[i].selected = false } }
                    Spacer()
                    if !IgnoreList.get("orphans").isEmpty {
                        Button("Réinitialiser les exclusions") { IgnoreList.reset("orphans"); model.scan() }
                    }
                    Button("Mettre à la corbeille") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.brown).disabled(model.selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Mettre \(model.selected.count) élément(s) à la corbeille ?", isPresented: $confirm) {
            Button("Mettre à la corbeille", role: .destructive) { model.trashSelected() }
        } message: { Text("Vous pourrez les restaurer depuis la corbeille si besoin.") }
    }
}
