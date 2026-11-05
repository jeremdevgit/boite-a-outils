// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import AppKit

// MARK: - Shell

struct ShellResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

enum Shell {
    @discardableResult
    static func exec(_ path: String, _ args: [String]) -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return ShellResult(status: -1, output: error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return ShellResult(status: p.terminationStatus, output: out)
    }

    @discardableResult
    static func sh(_ command: String) -> ShellResult { exec("/bin/zsh", ["-c", command]) }

    /// Exécute une commande en root : macOS affiche sa fenêtre de mot de passe.
    @discardableResult
    static func admin(_ command: String) -> ShellResult {
        appleScript("do shell script \"\(appleScriptEscape(command))\" with administrator privileges without altering line endings")
    }

    @discardableResult
    static func appleScript(_ source: String) -> ShellResult { exec("/usr/bin/osascript", ["-e", source]) }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Protège une chaîne pour zsh (guillemets simples).
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Fichiers

enum FS {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    static func children(_ url: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// Taille réellement occupée sur le disque (récursive).
    static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if v.isSymbolicLink == true { return 0 }
        if v.isRegularFile == true { return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        var total: Int64 = 0
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        for case let f as URL in en {
            autoreleasepool {
                if let fv = try? f.resourceValues(forKeys: Set(keys)), fv.isRegularFile == true {
                    total += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    static func remove(_ url: URL, permanently: Bool) throws {
        if permanently { try fm.removeItem(at: url) } else { try fm.trashItem(at: url, resultingItemURL: nil) }
        History.record(permanently ? "Supprimé" : "Corbeille", [url])
    }

    /// Met des éléments à la corbeille. Si `adminFallback`, ce qui résiste est confié au Finder
    /// (qui demande le mot de passe administrateur si nécessaire). Renvoie les éléments non supprimés.
    static func trash(_ urls: [URL], adminFallback: Bool) -> [URL] {
        let urls = urls.filter { exists($0) }
        var failed: [URL] = []
        for u in urls where exists(u) {
            do { try fm.trashItem(at: u, resultingItemURL: nil) } catch { failed.append(u) }
        }
        if adminFallback && !failed.isEmpty {
            let list = failed.map { "POSIX file \"\(Shell.appleScriptEscape($0.path))\"" }.joined(separator: ", ")
            Shell.appleScript("tell application \"Finder\" to delete {\(list)}")
            failed = failed.filter { exists($0) }
        }
        let failedSet = Set(failed)
        History.record("Corbeille", urls.filter { !failedSet.contains($0) })
        return failed
    }

    /// Info.plist d'une app, y compris les apps iPhone/iPad installées sur Mac (dossier WrappedBundle).
    static func appInfo(_ app: URL) -> [String: Any]? {
        for rel in ["Contents/Info.plist", "WrappedBundle/Info.plist"] {
            if let d = NSDictionary(contentsOf: app.appendingPathComponent(rel)) as? [String: Any] { return d }
        }
        return nil
    }

    static func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    static func chooseFolder(start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = "Choisir"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: home.path, with: "~", options: .anchored)
    }
}

func formatBytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

// MARK: - Permissions

enum Permissions {
    static var hasFullDiskAccess: Bool { PermissionCenter.checkFullDisk() == .granted }

    static func openSettings(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
}

// MARK: - Composants communs

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    var color: Color = .accentColor
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 50, height: 50)
                .background(RoundedRectangle(cornerRadius: 12).fill(color.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, icon: String, color: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, icon: icon, color: color) { EmptyView() }
    }
}

struct Card<Content: View>: View {
    var title: String? = nil
    var icon: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label(title, systemImage: icon ?? "circle").font(.headline)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
    }
}

struct Ring: View {
    let value: Double
    let color: Color
    var label: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label ?? "\(Int((value * 100).rounded())) %")
                .font(.title3.bold().monospacedDigit())
        }
        .frame(width: 92, height: 92)
        .animation(.easeOut(duration: 0.6), value: value)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 54)).foregroundStyle(.tertiary)
            Text(title).font(.title3.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// Fichier trouvé (gros fichiers, doublons).
struct FoundFile: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let modified: Date?
    var selected = false
}

struct FileRow: View {
    @Binding var file: FoundFile

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $file.selected).labelsHidden().toggleStyle(.checkbox)
            Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                .resizable().frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent).lineLimit(1)
                Text(FS.displayPath(file.url.deletingLastPathComponent()))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let d = file.modified {
                Text(d, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            Text(formatBytes(file.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Button { FS.reveal([file.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Afficher dans le Finder")
        }
        .padding(.vertical, 2)
    }
}

struct BottomBar<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) { content }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
        }
    }
}

// MARK: - État local

/// Équivalent de `@State` sans macro (le plugin SwiftUIMacros n'est livré qu'avec Xcode).
final class StateBox<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

@propertyWrapper
struct Local<T>: DynamicProperty {
    @StateObject private var box: StateBox<T>
    init(wrappedValue: T) { _box = StateObject(wrappedValue: StateBox(wrappedValue)) }
    var wrappedValue: T {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<T> { $box.value }
}

// MARK: - Historique des suppressions

enum History {
    static var url = FS.home.appendingPathComponent("Library/Logs/BoiteAOutils/historique.log")
    private static let queue = DispatchQueue(label: "history")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func record(_ action: String, _ paths: [URL]) {
        guard !paths.isEmpty else { return }
        queue.sync {
            try? FS.fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamp = formatter.string(from: Date())
            let lines = paths.map { "\(stamp)\t\(action)\t\($0.path)\n" }.joined()
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(lines.utf8))
                try? h.close()
            } else {
                try? lines.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Exclusions

/// Chemins que l'utilisateur ne veut plus voir proposés (par module).
enum IgnoreList {
    static func get(_ key: String) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "ignore.\(key)") ?? [])
    }
    static func add(_ key: String, _ url: URL) {
        var s = get(key)
        s.insert(url.path)
        UserDefaults.standard.set(Array(s), forKey: "ignore.\(key)")
    }
    static func reset(_ key: String) { UserDefaults.standard.removeObject(forKey: "ignore.\(key)") }
}
