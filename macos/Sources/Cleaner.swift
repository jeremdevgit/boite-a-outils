// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct CleanItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var selected: Bool
}

struct CleanCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let detail: String
    /// Vrai : suppression définitive (fichiers recréés automatiquement). Faux : mise à la corbeille.
    let permanent: Bool
    var items: [CleanItem]
    var expanded = false

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedTotal: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
}

struct CleanTarget {
    let id: String
    let name: String
    let icon: String
    let detail: String
    let roots: [String]          // relatifs au dossier personnel, ou absolus

    let permanent: Bool
    let preselected: Bool
    var olderThanDays: Int? = nil
    var excluded: Set<String> = []
    var matcher: ((URL) -> Bool)? = nil

    static let all: [CleanTarget] = [
        CleanTarget(id: "caches", name: String(localized: "Caches des applications"), icon: "archivebox.fill",
                    detail: String(localized: "Fichiers temporaires que les apps recréent automatiquement."),
                    roots: ["Library/Caches"], permanent: true, preselected: true,
                    excluded: ["com.boiteaoutils.mac", "CloudKit", "com.apple.HomeKit", "FamilyCircle", "com.apple.containermanagerd"]),
        CleanTarget(id: "logs", name: String(localized: "Journaux et rapports de plantage"), icon: "doc.text.fill",
                    detail: String(localized: "Historique technique des applications, inutile au quotidien."),
                    roots: ["Library/Logs"], permanent: true, preselected: true, excluded: ["BoiteAOutils"]),
        CleanTarget(id: "state", name: String(localized: "États sauvegardés des fenêtres"), icon: "macwindow.on.rectangle",
                    detail: String(localized: "Mémorisation des fenêtres ouvertes à la fermeture des apps."),
                    roots: ["Library/Saved Application State"], permanent: true, preselected: false),
        CleanTarget(id: "dev", name: String(localized: "Fichiers de développement"), icon: "hammer.fill",
                    detail: String(localized: "Xcode (DerivedData, DeviceSupport), caches de simulateurs, npm, Gradle."),
                    roots: ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
                            "Library/Developer/CoreSimulator/Caches", ".npm/_cacache", ".gradle/caches"],
                    permanent: true, preselected: true),
        CleanTarget(id: "trash", name: String(localized: "Corbeille"), icon: "trash.fill",
                    detail: String(localized: "Éléments déjà placés dans la corbeille."),
                    roots: [".Trash"], permanent: true, preselected: true),
        CleanTarget(id: "mail", name: String(localized: "Pièces jointes Mail téléchargées"), icon: "paperclip",
                    detail: String(localized: "Copies locales des pièces jointes ouvertes depuis Mail."),
                    roots: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"], permanent: false, preselected: false),
        CleanTarget(id: "ios", name: String(localized: "Sauvegardes iPhone / iPad"), icon: "iphone",
                    detail: String(localized: "Anciennes sauvegardes locales d'appareils iOS. À vérifier avant suppression !"),
                    roots: ["Library/Application Support/MobileSync/Backup"], permanent: false, preselected: false),
        CleanTarget(id: "installers", name: String(localized: "Installeurs inutiles"), icon: "shippingbox.fill",
                    detail: String(localized: "Images disque (.dmg), paquets (.pkg) et installeurs macOS déjà utilisés."),
                    roots: ["Downloads", "Desktop", "/Applications"], permanent: false, preselected: false,
                    matcher: { u in
                        ["dmg", "pkg", "mpkg", "xip", "iso"].contains(u.pathExtension.lowercased())
                            || (u.pathExtension == "app" && u.lastPathComponent.hasPrefix("Install macOS"))
                    }),
        CleanTarget(id: "downloads", name: String(localized: "Téléchargements de plus de 90 jours"), icon: "arrow.down.circle.fill",
                    detail: String(localized: "Fichiers anciens du dossier Téléchargements (envoyés à la corbeille)."),
                    roots: ["Downloads"], permanent: false, preselected: false, olderThanDays: 90),
    ]
}

final class CleanerModel: ObservableObject {
    @Published var categories: [CleanCategory] = []
    @Published var scanning = false
    @Published var cleaning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var lastResult: (freed: Int64, failed: Int)?

    var totalSize: Int64 { categories.reduce(0) { $0 + $1.total } }
    var selectedSize: Int64 { categories.reduce(0) { $0 + $1.selectedTotal } }
    var selectedCount: Int { categories.reduce(0) { $0 + $1.items.filter(\.selected).count } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var cats: [CleanCategory] = []
            let ignored: Set<String> = [".DS_Store", ".localized"]
            let userIgnored = IgnoreList.get("cleaner")
            var seen = Set<String>()
            for t in CleanTarget.all {
                DispatchQueue.main.async { self.status = String(localized: "Analyse : \(t.name)…") }
                var items: [CleanItem] = []
                for r in t.roots {
                    let base = r.hasPrefix("/") ? URL(fileURLWithPath: r) : FS.home.appendingPathComponent(r)
                    for child in FS.children(base) {
                        let name = child.lastPathComponent
                        if ignored.contains(name) || t.excluded.contains(name) { continue }
                        if userIgnored.contains(child.path) || seen.contains(child.path) { continue }
                        if let m = t.matcher, !m(child) { continue }
                        if let days = t.olderThanDays {
                            let v = try? child.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
                            let d = v?.addedToDirectoryDate ?? v?.contentModificationDate ?? Date()
                            if Date().timeIntervalSince(d) < Double(days) * 86_400 { continue }
                        }
                        let s = FS.size(of: child)
                        if s > 0 {
                            seen.insert(child.path)
                            items.append(CleanItem(url: child, size: s, selected: t.preselected))
                        }
                    }
                }
                items.sort { $0.size > $1.size }
                if !items.isEmpty {
                    cats.append(CleanCategory(id: t.id, name: t.name, icon: t.icon, detail: t.detail, permanent: t.permanent, items: items))
                }
            }
            DispatchQueue.main.async {
                self.categories = cats
                self.scanning = false
                self.scannedOnce = true
                self.status = ""
            }
        }
    }

    func ignore(_ item: CleanItem) {
        IgnoreList.add("cleaner", item.url)
        for c in categories.indices { categories[c].items.removeAll { $0.id == item.id } }
        categories.removeAll { $0.items.isEmpty }
    }

    func clean() {
        let work = categories.flatMap { c in c.items.filter(\.selected).map { ($0, c.permanent) } }
        guard !work.isEmpty else { return }
        cleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var failed = 0
            for (item, permanent) in work {
                do {
                    try FS.remove(item.url, permanently: permanent)
                    freed += item.size
                } catch {
                    // Les dossiers partiellement protégés sont vidés au mieux.
                    let remaining = FS.exists(item.url) ? FS.size(of: item.url) : 0
                    if remaining < item.size { freed += item.size - remaining } else { failed += 1 }
                }
            }
            DispatchQueue.main.async {
                self.cleaning = false
                self.lastResult = (freed, failed)
                self.scanning = false
                self.scan()
            }
        }
    }
}

struct CleanerView: View {
    @ObservedObject var model: CleanerModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Nettoyage système"), subtitle: String(localized: "Caches, journaux, corbeille et fichiers superflus"),
                       icon: "sparkles", color: .pink) {
                if model.scannedOnce && !model.scanning {
                    Button { model.scan() } label: { Label("Réanalyser", systemImage: "arrow.clockwise") }
                }
            }
            FullDiskAccessBanner()

            if let r = model.lastResult {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(String(localized: "\(formatBytes(r.freed)) libérés.") + (r.failed > 0 ? String(localized: " \(r.failed) élément(s) protégé(s) ignoré(s).") : ""))
                    Spacer()
                    Button { model.lastResult = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
                .padding(.horizontal, 24).padding(.top, 8)
            }

            if model.scanning || model.cleaning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.cleaning ? String(localized: "Nettoyage en cours…") : model.status).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "sparkles", title: String(localized: "Prêt à analyser"),
                           message: String(localized: "La Boîte à outils va rechercher les fichiers inutiles. Rien n'est supprimé sans votre accord."),
                           actionTitle: String(localized: "Lancer l'analyse")) { model.scan() }
            } else if model.categories.isEmpty {
                EmptyState(icon: "checkmark.seal", title: String(localized: "Votre Mac est propre"), message: String(localized: "Aucun fichier inutile trouvé."))
            } else {
                List {
                    ForEach($model.categories) { $cat in
                        DisclosureGroup(isExpanded: $cat.expanded) {
                            ForEach($cat.items) { $item in
                                HStack {
                                    Toggle("", isOn: $item.selected).labelsHidden().toggleStyle(.checkbox)
                                    Text(item.url.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Text(formatBytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button { FS.reveal([item.url]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                }
                                .contextMenu {
                                    Button("Afficher dans le Finder") { FS.reveal([item.url]) }
                                    Button("Toujours ignorer cet élément") { model.ignore(item) }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(
                                    get: { cat.items.allSatisfy(\.selected) },
                                    set: { v in for i in cat.items.indices { $cat.wrappedValue.items[i].selected = v } }
                                )).labelsHidden().toggleStyle(.checkbox)
                                Image(systemName: cat.icon).foregroundStyle(.pink).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(cat.name).bold()
                                    Text(cat.detail + (cat.permanent ? "" : String(localized: " → Corbeille")))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatBytes(cat.total)).monospacedDigit().bold()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))

                BottomBar {
                    VStack(alignment: .leading) {
                        Text("Sélection : \(formatBytes(model.selectedSize))").font(.headline)
                        Text("Trouvé au total : \(formatBytes(model.totalSize)) · clic droit sur un élément pour l'exclure")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Tout sélectionner") { for c in model.categories.indices { for i in model.categories[c].items.indices { model.categories[c].items[i].selected = true } } }
                    Button("Tout désélectionner") { for c in model.categories.indices { for i in model.categories[c].items.indices { model.categories[c].items[i].selected = false } } }
                    Spacer()
                    if !IgnoreList.get("cleaner").isEmpty {
                        Button("Réinitialiser les exclusions") { IgnoreList.reset("cleaner"); model.scan() }
                    }
                    Button("Nettoyer") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.pink).controlSize(.large)
                        .disabled(model.selectedCount == 0)
                }
            }
        }
        .confirmationDialog("Nettoyer \(formatBytes(model.selectedSize)) ?", isPresented: $confirm) {
            Button("Nettoyer", role: .destructive) { model.clean() }
        } message: {
            Text("Les caches et journaux sont supprimés définitivement ; les fichiers personnels sont envoyés à la corbeille. Il est conseillé de quitter les applications ouvertes avant.")
        }
    }
}
