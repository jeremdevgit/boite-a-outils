// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

struct AppEntry: Identifiable {
    var id: String { url.path }
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    var size: Int64?
    var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

struct Leftover: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var selected = true
}

final class UninstallerModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var selectedID: String? { didSet { findLeftovers() } }
    @Published var leftovers: [Leftover] = []
    @Published var searchingLeftovers = false
    @Published var search = ""
    @Published var sortBySize = false
    @Published var message: String?
    @Published var working = false

    static let userDirs = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers",
                           "Group Containers", "Saved Application State", "Logs", "HTTPStorages", "WebKit",
                           "LaunchAgents", "Cookies", "Application Scripts"]
    static let systemDirs = ["/Library/Application Support", "/Library/Caches", "/Library/Preferences",
                             "/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools", "/Library/Logs"]

    var selectedApp: AppEntry? { apps.first { $0.id == selectedID } }

    var visibleApps: [AppEntry] {
        var list = apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        if sortBySize { list.sort { ($0.size ?? 0) > ($1.size ?? 0) } }
        return list
    }

    func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var list: [AppEntry] = []
            for dir in [URL(fileURLWithPath: "/Applications"), FS.home.appendingPathComponent("Applications")] {
                for u in FS.children(dir) {
                    if u.pathExtension == "app" {
                        if let a = Self.entry(u) { list.append(a) }
                    } else if FS.isDirectory(u) {
                        for v in FS.children(u) where v.pathExtension == "app" { if let a = Self.entry(v) { list.append(a) } }
                    }
                }
            }
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = list
                self.loading = false
                self.computeSizes()
            }
        }
    }

    private static func entry(_ u: URL) -> AppEntry? {
        guard let info = FS.appInfo(u) else { return nil }
        return AppEntry(url: u, name: u.deletingPathExtension().lastPathComponent,
                        bundleID: info["CFBundleIdentifier"] as? String ?? "",
                        version: info["CFBundleShortVersionString"] as? String ?? "")
    }

    private func computeSizes() {
        let todo = apps.map(\.url)
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: todo.count) { i in
                let s = FS.size(of: todo[i])
                DispatchQueue.main.async {
                    if let idx = self.apps.firstIndex(where: { $0.url == todo[i] }) { self.apps[idx].size = s }
                }
            }
        }
    }

    func findLeftovers() {
        leftovers = []
        message = nil
        guard let app = selectedApp, !app.isApple else { return }
        searchingLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let bid = app.bundleID.lowercased()
            let name = app.name.lowercased()
            let compact = name.replacingOccurrences(of: " ", with: "")
            func matches(_ file: String) -> Bool {
                let n = file.lowercased()
                if bid.count > 4 && n.contains(bid) { return true }
                let base = (n as NSString).deletingPathExtension
                return name.count > 2 && (base == name || base == compact)
            }
            let dirs = Self.userDirs.map { FS.home.appendingPathComponent("Library/\($0)") }
                     + Self.systemDirs.map { URL(fileURLWithPath: $0) }
            var found: [Leftover] = []
            for d in dirs {
                for f in FS.children(d) where matches(f.lastPathComponent) {
                    found.append(Leftover(url: f, size: FS.size(of: f)))
                }
            }
            DispatchQueue.main.async {
                guard self.selectedID == app.id else { return }
                self.leftovers = found.sorted { $0.size > $1.size }
                self.searchingLeftovers = false
            }
        }
    }

    func uninstall(includeApp: Bool) {
        guard let app = selectedApp else { return }
        for r in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { r.terminate() }
        let targets = (includeApp ? [app.url] : []) + leftovers.filter(\.selected).map(\.url)
        working = true
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: includeApp ? 1 : 0)   // laisse le temps à l'app de se fermer
            let failed = FS.trash(targets, adminFallback: true)
            DispatchQueue.main.async {
                self.working = false
                if failed.isEmpty {
                    self.message = includeApp ? "\(app.name) a été désinstallé (éléments placés dans la corbeille)."
                                              : "Les fichiers résiduels ont été supprimés."
                    if includeApp { self.apps.removeAll { $0.id == app.id }; self.selectedID = nil }
                    else { self.findLeftovers() }
                } else {
                    self.message = "\(failed.count) élément(s) n'ont pas pu être supprimés : " + failed.map(\.lastPathComponent).joined(separator: ", ")
                }
            }
        }
    }
}

struct UninstallerView: View {
    @ObservedObject var model: UninstallerModel
    @Local private var confirmFull = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Désinstallateur", subtitle: "Supprimez une application et tous ses fichiers associés",
                       icon: "xmark.app.fill", color: .red) {
                Button { model.load() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            }
            HSplitView {
                VStack(spacing: 6) {
                    HStack {
                        TextField("Rechercher", text: $model.search).textFieldStyle(.roundedBorder)
                        Picker("", selection: $model.sortBySize) {
                            Text("Nom").tag(false); Text("Taille").tag(true)
                        }.pickerStyle(.segmented).frame(width: 120).labelsHidden()
                    }.padding(.horizontal, 10)
                    List(model.visibleApps, selection: $model.selectedID) { app in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                if app.isApple { Text("App système").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Text(app.size.map(formatBytes) ?? "…").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(app.id)
                    }
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

                detail.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
        .confirmationDialog("Désinstaller \(model.selectedApp?.name ?? "") ?", isPresented: $confirmFull) {
            Button("Désinstaller", role: .destructive) { model.uninstall(includeApp: true) }
        } message: { Text("L'application et les fichiers cochés seront placés dans la corbeille. L'application sera quittée si elle est ouverte.") }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selectedApp {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.bold())
                        Text([app.version.isEmpty ? nil : "Version \(app.version)", app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Application : \(app.size.map(formatBytes) ?? "…")").foregroundStyle(.secondary)
                    }
                }
                if app.isApple {
                    Label("Les applications Apple intégrées sont protégées par macOS et ne peuvent pas être supprimées.",
                          systemImage: "lock.fill").foregroundStyle(.secondary)
                } else {
                    Text("Fichiers associés").font(.headline)
                    if model.searchingLeftovers {
                        ProgressView().controlSize(.small)
                    } else if model.leftovers.isEmpty {
                        Text("Aucun fichier associé trouvé.").foregroundStyle(.secondary)
                    } else {
                        List($model.leftovers) { $l in
                            HStack {
                                Toggle("", isOn: $l.selected).labelsHidden().toggleStyle(.checkbox)
                                Text(FS.displayPath(l.url)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(formatBytes(l.size)).monospacedDigit().foregroundStyle(.secondary)
                                Button { FS.reveal([l.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
                            }
                        }
                        .listStyle(.bordered(alternatesRowBackgrounds: true))
                    }
                    if let m = model.message { Text(m).foregroundStyle(.secondary) }
                    HStack {
                        let extra = model.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
                        Text("Total : \(formatBytes((app.size ?? 0) + extra))").font(.headline)
                        Spacer()
                        if model.working { ProgressView().controlSize(.small) }
                        Button("Supprimer les restes seulement") { model.uninstall(includeApp: false) }
                            .disabled(model.leftovers.filter(\.selected).isEmpty || model.working)
                        Button("Désinstaller") { confirmFull = true }
                            .buttonStyle(.borderedProminent).tint(.red).disabled(model.working)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        } else {
            VStack(spacing: 10) {
                if let m = model.message { Label(m, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                EmptyState(icon: "app.dashed", title: "Sélectionnez une application",
                           message: "La Boîte à outils retrouve ses préférences, caches, conteneurs et agents de lancement pour une désinstallation complète.")
            }
        }
    }
}
