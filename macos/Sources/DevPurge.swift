// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct DevRule {
    let dir: String
    let markers: [String]      // fichiers attendus dans le dossier parent ; vide = venv Python
    let kind: String

    static let all: [DevRule] = [
        DevRule(dir: "node_modules", markers: ["package.json"], kind: "Node.js"),
        DevRule(dir: ".next", markers: ["package.json"], kind: "Next.js"),
        DevRule(dir: ".nuxt", markers: ["package.json"], kind: "Nuxt"),
        DevRule(dir: ".parcel-cache", markers: ["package.json"], kind: "Parcel"),
        DevRule(dir: ".angular", markers: ["angular.json"], kind: "Angular"),
        DevRule(dir: "Pods", markers: ["Podfile"], kind: "CocoaPods"),
        DevRule(dir: ".build", markers: ["Package.swift"], kind: "Swift"),
        DevRule(dir: "target", markers: ["Cargo.toml", "pom.xml"], kind: "Rust / Maven"),
        DevRule(dir: "build", markers: ["build.gradle", "build.gradle.kts"], kind: "Gradle"),
        DevRule(dir: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], kind: "Gradle"),
        DevRule(dir: ".venv", markers: [], kind: "Python"),
        DevRule(dir: "venv", markers: [], kind: "Python"),
    ]

    func matches(_ url: URL) -> Bool {
        guard url.lastPathComponent == dir else { return false }
        if markers.isEmpty { return FS.exists(url.appendingPathComponent("pyvenv.cfg")) }
        let parent = url.deletingLastPathComponent()
        return markers.contains { FS.exists(parent.appendingPathComponent($0)) }
    }
}

struct DevArtifact: Identifiable {
    let id = UUID()
    let url: URL
    let kind: String
    let lastActivity: Date?
    var size: Int64?
    var selected: Bool
    var project: String { url.deletingLastPathComponent().lastPathComponent }
}

/// Dépendances et fichiers de compilation régénérables (inspiré de « mo purge »).
final class DevPurgeModel: ObservableObject {
    @Published var root = FS.home
    @Published var items: [DevArtifact] = []
    @Published var scanning = false
    @Published var scannedOnce = false
    @Published var status = ""
    @Published var message: String?
    var cancelled = false

    var selected: [DevArtifact] { items.filter(\.selected) }
    var selectedSize: Int64 { selected.reduce(0) { $0 + ($1.size ?? 0) } }
    var total: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    func scan() {
        cancelled = false
        scanning = true
        message = nil
        items = []
        let root = root
        DispatchQueue.global(qos: .userInitiated).async {
            let ruleNames = Set(DevRule.all.map(\.dir))
            let skip: Set<String> = [FS.home.appendingPathComponent("Library").path, FS.home.appendingPathComponent(".Trash").path]
            let keys: [URLResourceKey] = [.isDirectoryKey]
            var found: [DevArtifact] = []
            var n = 0
            let en = FS.fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
                                      errorHandler: { _, _ in true })
            while let u = en?.nextObject() as? URL {
                if self.cancelled { break }
                guard (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                n += 1
                if n % 500 == 0 { let c = n; DispatchQueue.main.async { self.status = "\(c) dossiers parcourus…" } }
                let name = u.lastPathComponent
                if skip.contains(u.path) { en?.skipDescendants(); continue }
                if let rule = DevRule.all.first(where: { $0.matches(u) }) {
                    let activity = Self.lastActivity(of: u.deletingLastPathComponent(), excluding: ruleNames)
                    let old = activity.map { Date().timeIntervalSince($0) > 30 * 86_400 } ?? true
                    found.append(DevArtifact(url: u, kind: rule.kind, lastActivity: activity, size: nil, selected: old))
                    en?.skipDescendants()
                } else if name.hasPrefix(".") {
                    en?.skipDescendants()     // dossiers cachés (caches, configs) : hors périmètre
                }
            }
            DispatchQueue.main.async { self.status = "Calcul des tailles…" }
            var sizes = [Int64](repeating: 0, count: found.count)
            let urls = found.map(\.url)
            sizes.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: urls.count) { i in buf[i] = FS.size(of: urls[i]) }
            }
            for i in found.indices { found[i].size = sizes[i] }
            found.sort { ($0.size ?? 0) > ($1.size ?? 0) }
            DispatchQueue.main.async {
                self.items = found
                self.scanning = false
                self.scannedOnce = true
                self.status = ""
            }
        }
    }

    /// Date de dernière modification d'un projet (hors dossiers générés).
    private static func lastActivity(of project: URL, excluding: Set<String>) -> Date? {
        FS.children(project)
            .filter { !excluding.contains($0.lastPathComponent) }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    func purge() {
        let work = selected
        scanning = true
        status = "Suppression…"
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var removed = Set<UUID>()
            for a in work {
                if (try? FS.remove(a.url, permanently: true)) != nil {
                    freed += a.size ?? 0
                    removed.insert(a.id)
                }
            }
            DispatchQueue.main.async {
                self.items.removeAll { removed.contains($0.id) }
                self.scanning = false
                self.message = "\(formatBytes(freed)) libérés (\(removed.count) dossiers)."
            }
        }
    }
}

struct DevPurgeView: View {
    @ObservedObject var model: DevPurgeModel
    @Local private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Projets de dev", subtitle: "node_modules, Pods, target, .build, venv… régénérables à la demande",
                       icon: "curlybraces.square.fill", color: .mint)

            HStack(spacing: 14) {
                Button { if let u = FS.chooseFolder(start: model.root) { model.root = u } } label: {
                    Label(FS.displayPath(model.root), systemImage: "folder")
                }
                Spacer()
                if model.scanning {
                    Button("Arrêter") { model.cancelled = true }
                } else {
                    Button("Rechercher") { model.scan() }.buttonStyle(.borderedProminent).tint(.mint)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 10)
            if let m = model.message {
                Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .padding(.horizontal, 24).padding(.bottom, 6).frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.scanning {
                VStack(spacing: 10) { ProgressView(); Text(model.status).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !model.scannedOnce {
                EmptyState(icon: "curlybraces", title: "Alléger vos projets",
                           message: "Recherche les dépendances et fichiers de compilation de vos projets. Ceux inactifs depuis plus de 30 jours sont présélectionnés.",
                           actionTitle: "Rechercher") { model.scan() }
            } else if model.items.isEmpty {
                EmptyState(icon: "checkmark.seal", title: "Rien à purger", message: "Aucun dossier de dépendances trouvé.")
            } else {
                List($model.items) { $a in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $a.selected).labelsHidden().toggleStyle(.checkbox)
                        Text(a.kind).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.mint.opacity(0.2))).frame(width: 100, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(a.project) / \(a.url.lastPathComponent)").lineLimit(1)
                            Text(FS.displayPath(a.url.deletingLastPathComponent()))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let d = a.lastActivity {
                            Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(a.size.map(formatBytes) ?? "…").monospacedDigit().frame(width: 80, alignment: .trailing)
                        Button { FS.reveal([a.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                BottomBar {
                    VStack(alignment: .leading) {
                        Text("Sélection : \(formatBytes(model.selectedSize))").font(.headline)
                        Text("\(model.items.count) dossiers · \(formatBytes(model.total)) au total").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Supprimer") { confirm = true }
                        .buttonStyle(.borderedProminent).tint(.mint).disabled(model.selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Supprimer \(model.selected.count) dossier(s) (\(formatBytes(model.selectedSize))) ?", isPresented: $confirm) {
            Button("Supprimer définitivement", role: .destructive) { model.purge() }
        } message: {
            Text("Ces dossiers se régénèrent avec npm install, pod install, cargo build, swift build, etc. Votre code source n'est pas touché.")
        }
    }
}
