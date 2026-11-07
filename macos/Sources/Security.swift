// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import CoreAudio
import CoreMediaIO
import CryptoKit
import UserNotifications

// MARK: - Signature de code

struct SignatureInfo {
    enum Level { case apple, developer, adhoc, unsigned, invalid, missing }
    let level: Level
    let authority: String

    var label: String {
        switch level {
        case .apple: "Apple"
        case .developer: authority
        case .adhoc: String(localized: "Signature locale (non vérifiée)")
        case .unsigned: String(localized: "Non signé")
        case .invalid: String(localized: "Signature invalide")
        case .missing: String(localized: "Fichier introuvable")
        }
    }
    var suspicious: Bool { level == .unsigned || level == .invalid || level == .adhoc || level == .missing }

    static func check(_ path: String) -> SignatureInfo {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return SignatureInfo(level: .missing, authority: "") }
        let d = Shell.exec("/usr/bin/codesign", ["-dv", "--verbose=2", path]).output
        if d.contains("not signed") { return SignatureInfo(level: .unsigned, authority: "") }
        let authority = d.components(separatedBy: "\n").first { $0.hasPrefix("Authority=") }.map { String($0.dropFirst(10)) } ?? ""
        if !Shell.exec("/usr/bin/codesign", ["-v", path]).ok { return SignatureInfo(level: .invalid, authority: authority) }
        if authority.isEmpty || d.contains("Signature=adhoc") { return SignatureInfo(level: .adhoc, authority: "") }
        if authority.contains("Software Signing") || authority.hasPrefix("Apple ") { return SignatureInfo(level: .apple, authority: authority) }
        return SignatureInfo(level: .developer, authority: authority.replacingOccurrences(of: "Developer ID Application: ", with: ""))
    }

    static func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Persistance (inspiré de KnockKnock)

struct PersistentItem: Identifiable {
    let id = UUID()
    let category: String
    let name: String
    let path: String          // fichier de configuration ou bundle
    let executable: String    // ce qui s'exécute réellement
    var signature: SignatureInfo?
}

enum Persistence {
    static let watchedDirs: [String] = [
        FS.home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/StartupItems",
    ]

    static func scan() -> [PersistentItem] {
        var items: [PersistentItem] = []
        let home = FS.home.path
        for (dir, cat) in [("\(home)/Library/LaunchAgents", String(localized: "Agents de lancement (utilisateur)")),
                           ("/Library/LaunchAgents", String(localized: "Agents de lancement (tous)")),
                           ("/Library/LaunchDaemons", String(localized: "Services système (daemons)"))] {
            for f in FS.children(URL(fileURLWithPath: dir)) where f.pathExtension == "plist" {
                let d = NSDictionary(contentsOf: f) as? [String: Any]
                let exe = (d?["Program"] as? String) ?? (d?["ProgramArguments"] as? [String])?.first ?? ""
                items.append(PersistentItem(category: cat, name: d?["Label"] as? String ?? f.lastPathComponent, path: f.path, executable: exe))
            }
        }
        let bundleDirs: [(String, String)] = [
            ("/Library/PrivilegedHelperTools", String(localized: "Outils privilégiés")),
            ("\(home)/Library/PreferencePanes", String(localized: "Panneaux de préférences")), ("/Library/PreferencePanes", String(localized: "Panneaux de préférences")),
            ("\(home)/Library/Internet Plug-Ins", String(localized: "Plug-ins Internet")), ("/Library/Internet Plug-Ins", String(localized: "Plug-ins Internet")),
            ("\(home)/Library/QuickLook", String(localized: "Plug-ins Coup d'œil")), ("/Library/QuickLook", String(localized: "Plug-ins Coup d'œil")),
            ("\(home)/Library/Spotlight", String(localized: "Importateurs Spotlight")), ("/Library/Spotlight", String(localized: "Importateurs Spotlight")),
            ("/Library/Audio/Plug-Ins/HAL", String(localized: "Pilotes audio")), ("\(home)/Library/Screen Savers", String(localized: "Économiseurs d'écran")),
            ("/Library/Screen Savers", String(localized: "Économiseurs d'écran")), ("\(home)/Library/Input Methods", String(localized: "Méthodes de saisie")),
            ("/Library/Input Methods", String(localized: "Méthodes de saisie")), ("/Library/StartupItems", String(localized: "Éléments de démarrage (anciens)")),
            ("/Library/Extensions", String(localized: "Extensions noyau (kext)")),
        ]
        for (dir, cat) in bundleDirs {
            for f in FS.children(URL(fileURLWithPath: dir)) where !f.lastPathComponent.hasPrefix(".") {
                items.append(PersistentItem(category: cat, name: f.lastPathComponent, path: f.path, executable: f.path))
            }
        }
        // Extensions système (réseau, sécurité, pilotes)
        for line in Shell.exec("/usr/bin/systemextensionsctl", ["list"]).output.components(separatedBy: "\n") where line.contains("\t") && line.contains("[") {
            let parts = line.components(separatedBy: "\t").filter { !$0.isEmpty }
            if parts.count >= 5 {
                items.append(PersistentItem(category: String(localized: "Extensions système"), name: parts[parts.count - 2] + " " + parts.last!,
                                            path: parts[parts.count - 3], executable: ""))
            }
        }
        // Tâches planifiées
        let cron = Shell.exec("/usr/bin/crontab", ["-l"])
        if cron.ok {
            for line in cron.output.components(separatedBy: "\n") where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
                items.append(PersistentItem(category: String(localized: "Tâches cron"), name: line, path: "", executable: ""))
            }
        }
        // Profils de configuration (MDM, VPN, restrictions…)
        for line in Shell.exec("/usr/bin/profiles", ["list"]).output.components(separatedBy: "\n") where line.contains("profileIdentifier") {
            items.append(PersistentItem(category: String(localized: "Profils de configuration"), name: line.components(separatedBy: ": ").last ?? line, path: "", executable: ""))
        }
        return items
    }
}

// MARK: - Surveillance (inspiré de BlockBlock et OverSight)

final class SecurityMonitor: ObservableObject {
    static let shared = SecurityMonitor()

    struct Event: Identifiable { let id = UUID(); let date = Date(); let icon: String; let text: String; let path: String? }

    @Published var events: [Event] = []
    @Published var cameraOn = false
    @Published var micOn = false
    @Published var persistenceWatch = UserDefaults.standard.object(forKey: "watchPersistence") as? Bool ?? false {
        didSet { UserDefaults.standard.set(persistenceWatch, forKey: "watchPersistence"); configure() }
    }
    @Published var avWatch = UserDefaults.standard.object(forKey: "watchCamMic") as? Bool ?? false {
        didSet { UserDefaults.standard.set(avWatch, forKey: "watchCamMic"); configure() }
    }

    private var sources: [DispatchSourceFileSystemObject] = []
    private var snapshot: [String: Set<String>] = [:]
    private var avTimer: Timer?

    func configure() {
        sources.forEach { $0.cancel() }
        sources = []
        if persistenceWatch {
            for dir in Persistence.watchedDirs {
                snapshot[dir] = Set(FS.children(URL(fileURLWithPath: dir)).map(\.lastPathComponent))
                let fd = open(dir, O_EVTONLY)
                guard fd >= 0 else { continue }
                let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
                src.setEventHandler { [weak self] in self?.directoryChanged(dir) }
                src.setCancelHandler { close(fd) }
                src.resume()
                sources.append(src)
            }
        }
        avTimer?.invalidate()
        avTimer = nil
        if avWatch {
            pollAV()
            avTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.pollAV() }
        } else {
            cameraOn = false
            micOn = false
        }
    }

    private func directoryChanged(_ dir: String) {
        let now = Set(FS.children(URL(fileURLWithPath: dir)).map(\.lastPathComponent))
        let added = now.subtracting(snapshot[dir] ?? [])
        snapshot[dir] = now
        for name in added where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            let sig = SignatureInfo.check(NSDictionary(contentsOfFile: path).flatMap {
                ($0["Program"] as? String) ?? ($0["ProgramArguments"] as? [String])?.first } ?? path)
            log("lock.trianglebadge.exclamationmark", String(localized: "Nouvel élément de démarrage : \(name) — \(sig.label)"), path: path)
            notify(String(localized: "Nouvel élément lancé au démarrage"), String(localized: "\(name)\nDans \(dir)\nSignature : \(sig.label)"))
        }
    }

    private func pollAV() {
        let cam = Self.cameraInUse(), mic = Self.microphoneInUse()
        if cam != cameraOn {
            cameraOn = cam
            log(cam ? "video.fill" : "video.slash", cam ? String(localized: "Caméra activée") : String(localized: "Caméra désactivée"), path: nil)
            if cam { notify(String(localized: "Caméra activée"), String(localized: "Une application utilise la caméra.")) }
        }
        if mic != micOn {
            micOn = mic
            log(mic ? "mic.fill" : "mic.slash", mic ? String(localized: "Micro activé") : String(localized: "Micro désactivé"), path: nil)
            if mic { notify(String(localized: "Micro activé"), String(localized: "Une application utilise le micro.")) }
        }
    }

    private func log(_ icon: String, _ text: String, path: String?) {
        events.insert(Event(icon: icon, text: text, path: path), at: 0)
        if events.count > 200 { events.removeLast() }
    }

    private func notify(_ title: String, _ body: String) {
        NSSound(named: "Funk")?.play()
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0 else { return false }
        var devices = [CMIODeviceID](repeating: 0, count: Int(size) / MemoryLayout<CMIODeviceID>.size)
        var used: UInt32 = 0
        CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices)
        for d in devices {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(d, &a, 0, nil, s, &s, &running) == 0, running != 0 { return true }
        }
        return false
    }

    static func microphoneInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices)
        for d in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var ss: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(d, &streams, 0, nil, &ss) == noErr, ss > 0 else { continue }
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d, &a, 0, nil, &s, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}

// MARK: - Connexions réseau (inspiré de LuLu, en lecture seule)

struct NetConnection: Identifiable {
    let id = UUID()
    let process: String
    let pid: Int32
    let proto: String
    let local: String
    let remote: String
    let state: String
}

// MARK: - Modèle et vue

final class SecurityModel: ObservableObject {
    @Published var items: [PersistentItem] = []
    @Published var scanning = false
    @Published var connections: [NetConnection] = []
    @Published var loadingConnections = false
    @Published var hideApple = true

    var visible: [PersistentItem] { items.filter { !hideApple || $0.signature?.level != .apple } }
    var categories: [String] { visible.map(\.category).reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
    var suspiciousCount: Int { items.filter { $0.signature?.suspicious == true }.count }

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var list = Persistence.scan()
            let exes = list.map(\.executable)
            var sigs = [SignatureInfo?](repeating: nil, count: exes.count)
            sigs.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: exes.count) { i in
                    if !exes[i].isEmpty { buf[i] = SignatureInfo.check(exes[i]) }
                }
            }
            for i in list.indices { list[i].signature = sigs[i] }
            DispatchQueue.main.async {
                self.items = list
                self.scanning = false
            }
        }
    }

    func loadConnections(admin: Bool) {
        loadingConnections = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cmd = "/usr/sbin/lsof -i -n -P -F pcPnTt"
            let out = admin ? Shell.admin(cmd).output : Shell.sh(cmd).output
            var list: [NetConnection] = []
            var pid: Int32 = 0, name = "", proto = "", state = ""
            for line in out.components(separatedBy: "\n") {
                guard let tag = line.first else { continue }
                let v = String(line.dropFirst())
                switch tag {
                case "p": pid = Int32(v) ?? 0
                case "c": name = v
                case "P": proto = v
                case "T": if v.hasPrefix("ST=") { state = String(v.dropFirst(3)) }
                case "n":
                    let parts = v.components(separatedBy: "->")
                    list.append(NetConnection(process: name, pid: pid, proto: proto, local: parts[0],
                                              remote: parts.count > 1 ? parts[1] : "", state: state))
                    state = ""
                default: break
                }
            }
            DispatchQueue.main.async {
                self.connections = list
                self.loadingConnections = false
            }
        }
    }
}

struct SecurityView: View {
    @ObservedObject var model: SecurityModel
    @ObservedObject var monitor = SecurityMonitor.shared
    @Local private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: String(localized: "Sécurité"), subtitle: String(localized: "Ce qui se lance tout seul, ce qui vous écoute, ce qui se connecte"),
                       icon: "shield.lefthalf.filled", color: .red) {
                Picker("", selection: $tab) {
                    Text("Persistance").tag(0); Text("Surveillance").tag(1); Text("Connexions").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }
            switch tab {
            case 0: persistence
            case 1: surveillance
            default: connections
            }
        }
        .onAppear { if model.items.isEmpty { model.scan() } }
    }

    // Persistance
    private var persistence: some View {
        VStack(spacing: 0) {
            HStack {
                if model.scanning { ProgressView().controlSize(.small); Text("Vérification des signatures…").foregroundStyle(.secondary) }
                else {
                    Label(model.suspiciousCount == 0 ? "Aucun élément non signé." : "\(model.suspiciousCount) élément(s) non signé(s) ou invalide(s) à vérifier.",
                          systemImage: model.suspiciousCount == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.suspiciousCount == 0 ? .green : .orange)
                }
                Spacer()
                Toggle("Masquer les éléments Apple", isOn: $model.hideApple).toggleStyle(.checkbox)
                Button { model.scan() } label: { Label("Analyser", systemImage: "arrow.clockwise") }
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
            List {
                ForEach(model.categories, id: \.self) { cat in
                    Section(cat) {
                        ForEach(model.visible.filter { $0.category == cat }) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.signature?.suspicious == true ? "exclamationmark.triangle.fill" : "checkmark.seal")
                                    .foregroundStyle(item.signature?.suspicious == true ? .orange : .green).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1)
                                    Text(item.executable.isEmpty ? item.path : item.executable)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if let s = item.signature { Text(s.label).font(.caption).foregroundStyle(s.suspicious ? .orange : .secondary).lineLimit(1) }
                                if !item.path.isEmpty {
                                    Button { FS.reveal([URL(fileURLWithPath: item.path)]) } label: { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(.borderless)
                                }
                            }
                            .contextMenu {
                                if !item.path.isEmpty { Button("Afficher dans le Finder") { FS.reveal([URL(fileURLWithPath: item.path)]) } }
                                if !item.executable.isEmpty {
                                    Button("Rechercher sur VirusTotal") {
                                        DispatchQueue.global().async {
                                            guard let h = SignatureInfo.sha256(item.executable),
                                                  let u = URL(string: "https://www.virustotal.com/gui/file/\(h)") else { return }
                                            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            BottomBar {
                Text("Pour désactiver un agent ou un service : module « Démarrage ». Clic droit : VirusTotal (seule l'empreinte du fichier est envoyée).")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    // Surveillance
    private var surveillance: some View {
        Form {
            Section {
                Toggle(isOn: $monitor.persistenceWatch) {
                    VStack(alignment: .leading) {
                        Text("Alerter quand un logiciel s'installe au démarrage")
                        Text("Surveille les dossiers LaunchAgents, LaunchDaemons et outils privilégiés (façon BlockBlock).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $monitor.avWatch) {
                    VStack(alignment: .leading) {
                        Text("Alerter quand la caméra ou le micro s'allument")
                        Text("Façon OverSight. Les alertes s'affichent même fenêtre fermée (l'app reste dans la barre des menus).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if monitor.avWatch {
                    HStack(spacing: 20) {
                        Label(monitor.cameraOn ? "Caméra active" : "Caméra inactive", systemImage: monitor.cameraOn ? "video.fill" : "video.slash")
                            .foregroundStyle(monitor.cameraOn ? .red : .secondary)
                        Label(monitor.micOn ? "Micro actif" : "Micro inactif", systemImage: monitor.micOn ? "mic.fill" : "mic.slash")
                            .foregroundStyle(monitor.micOn ? .red : .secondary)
                    }
                }
            } footer: {
                Text("Les notifications nécessitent l'autorisation « Notifications » (onglet Autorisations).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Journal des alertes") {
                if monitor.events.isEmpty { Text("Aucun événement depuis le lancement.").foregroundStyle(.secondary) }
                ForEach(monitor.events) { e in
                    HStack {
                        Image(systemName: e.icon).frame(width: 20)
                        Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.text)
                        Spacer()
                        if let p = e.path { Button { FS.reveal([URL(fileURLWithPath: p)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // Connexions
    private var connections: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Mes applications") { model.loadConnections(admin: false) }
                Button("Tout le système (administrateur)") { model.loadConnections(admin: true) }
                if model.loadingConnections { ProgressView().controlSize(.small) }
                Spacer()
                Text("\(model.connections.count) connexions").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.bottom, 8)
            let groups = Dictionary(grouping: model.connections, by: \.process).sorted { $0.value.count > $1.value.count }
            List {
                ForEach(groups, id: \.key) { name, conns in
                    Section("\(name) — \(conns.count)") {
                        ForEach(conns) { c in
                            HStack {
                                Text(c.proto).font(.caption.monospaced()).frame(width: 36, alignment: .leading)
                                Text(c.remote.isEmpty ? String(localized: "En écoute sur \(c.local)") : c.remote).font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(c.remote.isEmpty ? .orange : .primary).textSelection(.enabled)
                                Spacer()
                                Text(c.state).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onAppear { if model.connections.isEmpty { model.loadConnections(admin: false) } }
            BottomBar {
                Text("Lecture seule. Pour bloquer une app, il faut un pare-feu sortant dédié comme LuLu (Objective-See, gratuit).")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
