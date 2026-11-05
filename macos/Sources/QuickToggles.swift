// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

// MARK: - Fonctions système partagées

enum Mac {
    static func readDefault(_ domain: String, _ key: String, currentHost: Bool = false) -> String? {
        let r = Shell.exec("/usr/bin/defaults", (currentHost ? ["-currentHost"] : []) + ["read", domain, key])
        return r.ok ? r.output : nil
    }

    static var isDark: Bool { readDefault("-g", "AppleInterfaceStyle") == "Dark" }

    static func setDark(_ on: Bool) {
        Shell.appleScript("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
    }

    static func postColorChange() {
        let c = DistributedNotificationCenter.default()
        for n in ["AppleColorPreferencesChangedNotification", "AppleAquaColorVariantChanged", "AppleInterfaceThemeChangedNotification"] {
            c.postNotificationName(.init(n), object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Interface Wi-Fi (en0 la plupart du temps).
    static var wifiDevice: String? {
        let lines = Shell.exec("/usr/sbin/networksetup", ["-listallhardwareports"]).output.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() where l.contains("Wi-Fi") || l.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") { return String(lines[i + 1].dropFirst(8)) }
        }
        return nil
    }

    static func killall(_ process: String) { Shell.exec("/usr/bin/killall", [process]) }
}

// MARK: - Garder éveillé (inspiré d'Amphetamine / KeepingYouAwake)

final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()
    @Published private(set) var active = false
    @Published private(set) var until: Date?
    @Published var allowDisplaySleep = false
    private var process: Process?

    static let durations: [(String, Int?)] = [("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120), ("5 h", 300), ("Indéfiniment", nil)]

    func start(minutes: Int?) {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w : s'arrête automatiquement si la Boîte à outils est quittée
        var args = [allowDisplaySleep ? "-i" : "-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if let m = minutes { args += ["-t", String(m * 60)] }
        p.arguments = args
        p.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.active = false
                self.until = nil
            }
        }
        guard (try? p.run()) != nil else { return }
        process = p
        active = true
        until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
    }

    func stop() {
        let p = process
        process = nil
        p?.terminate()
        active = false
        until = nil
    }
}

// MARK: - Interrupteurs (inspiré de One Switch / Switch Manager)

struct QuickToggle: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    let read: () -> Bool
    let write: (Bool) -> Void
}

final class QuickTogglesModel: ObservableObject {
    @Published var states: [String: Bool] = [:]
    @Published var busy: Set<String> = []
    @Published var message: String?

    let toggles: [QuickToggle] = {
        let wifi = Mac.wifiDevice
        var list = [
            QuickToggle(id: "dark", title: "Mode sombre", icon: "moon.fill", detail: "Bascule l'apparence de macOS.",
                        read: { Mac.isDark }, write: { Mac.setDark($0) }),
            QuickToggle(id: "desktop", title: "Masquer les icônes du bureau", icon: "menubar.dock.rectangle",
                        detail: "Idéal pour une présentation ou un partage d'écran.",
                        read: { Mac.readDefault("com.apple.finder", "CreateDesktop") == "0" },
                        write: { on in
                            if on { Shell.exec("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", "false"]) }
                            else { Shell.exec("/usr/bin/defaults", ["delete", "com.apple.finder", "CreateDesktop"]) }
                            Mac.killall("Finder")
                        }),
            QuickToggle(id: "hidden", title: "Afficher les fichiers cachés", icon: "eye", detail: "Dans toutes les fenêtres du Finder.",
                        read: { Mac.readDefault("com.apple.finder", "AppleShowAllFiles") == "1" },
                        write: { on in
                            Shell.exec("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", on ? "true" : "false"])
                            Mac.killall("Finder")
                        }),
            QuickToggle(id: "mute", title: "Couper le son", icon: "speaker.slash.fill", detail: "Sortie audio principale.",
                        read: { Shell.appleScript("output muted of (get volume settings)").output == "true" },
                        write: { Shell.appleScript("set volume output muted \($0)") }),
            QuickToggle(id: "lowpower", title: "Mode économie d'énergie", icon: "leaf.fill",
                        detail: "Réduit la consommation (mot de passe administrateur).",
                        read: { Shell.exec("/usr/bin/pmset", ["-g"]).output.range(of: #"lowpowermode\s+1"#, options: .regularExpression) != nil },
                        write: { Shell.admin("pmset -a lowpowermode \($0 ? 1 : 0)") }),
        ]
        if let wifi {
            list.insert(QuickToggle(id: "wifi", title: "Wi-Fi", icon: "wifi", detail: "Active ou coupe le Wi-Fi (\(wifi)).",
                                    read: { Shell.exec("/usr/sbin/networksetup", ["-getairportpower", wifi]).output.hasSuffix("On") },
                                    write: { Shell.exec("/usr/sbin/networksetup", ["-setairportpower", wifi, $0 ? "on" : "off"]) }), at: 3)
        }
        return list
    }()

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            var s: [String: Bool] = [:]
            for t in self.toggles { s[t.id] = t.read() }
            DispatchQueue.main.async { self.states = s }
        }
    }

    func set(_ t: QuickToggle, _ on: Bool) {
        states[t.id] = on
        busy.insert(t.id)
        DispatchQueue.global(qos: .userInitiated).async {
            t.write(on)
            let real = t.read()
            DispatchQueue.main.async {
                self.busy.remove(t.id)
                self.states[t.id] = real
            }
        }
    }

    func action(_ title: String, _ work: @escaping () -> ShellResult) {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = work()
            DispatchQueue.main.async { self.message = r.ok ? "\(title) : fait." : "\(title) : échec. \(r.output)" }
        }
    }
}

struct QuickTogglesView: View {
    @ObservedObject var model: QuickTogglesModel
    @ObservedObject var awake = KeepAwake.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Interrupteurs", subtitle: "Les réglages du quotidien, en un clic",
                           icon: "switch.2", color: .orange) {
                    Button { model.refresh() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                }

                Group {
                    Card(title: "Garder le Mac éveillé", icon: "cup.and.saucer.fill") {
                        HStack {
                            if awake.active {
                                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.orange)
                                if let u = awake.until {
                                    Text("Actif jusqu'à \(u.formatted(date: .omitted, time: .shortened))")
                                } else {
                                    Text("Actif indéfiniment")
                                }
                                Spacer()
                                Button("Arrêter") { awake.stop() }
                            } else {
                                Text("Empêche la mise en veille (téléchargement, présentation, rendu…).").foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        HStack {
                            ForEach(KeepAwake.durations, id: \.0) { d in
                                Button(d.0) { awake.start(minutes: d.1) }
                            }
                        }
                        Toggle("Autoriser l'écran à s'éteindre (le Mac reste actif)", isOn: $awake.allowDisplaySleep)
                            .toggleStyle(.checkbox)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(model.toggles) { t in
                            Card {
                                HStack(spacing: 12) {
                                    Image(systemName: t.icon).font(.title2).frame(width: 30)
                                        .foregroundStyle(model.states[t.id] == true ? Color.orange : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).bold()
                                        Text(t.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if model.busy.contains(t.id) { ProgressView().controlSize(.small) }
                                    Toggle("", isOn: Binding(get: { model.states[t.id] ?? false }, set: { model.set(t, $0) }))
                                        .toggleStyle(.switch).labelsHidden()
                                }
                            }
                        }
                    }

                    Card(title: "Actions rapides", icon: "bolt.fill") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                            actionButton("Éteindre l'écran (verrouille)", "display") {
                                Shell.exec("/usr/bin/pmset", ["displaysleepnow"])
                            }
                            actionButton("Économiseur d'écran", "sparkles.tv") {
                                Shell.exec("/usr/bin/open", ["-a", "ScreenSaverEngine"])
                            }
                            actionButton("Éjecter tous les disques", "eject.fill") {
                                Shell.appleScript("tell application \"Finder\" to eject (every disk whose ejectable is true)")
                            }
                            actionButton("Vider la corbeille", "trash") {
                                Shell.appleScript("tell application \"Finder\" to empty trash")
                            }
                            actionButton("Relancer le Finder", "arrow.clockwise") { Shell.exec("/usr/bin/killall", ["Finder"]) }
                            actionButton("Relancer le Dock", "dock.rectangle") { Shell.exec("/usr/bin/killall", ["Dock"]) }
                        }
                        if let m = model.message { Text(m).font(.callout).foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { model.refresh() }
    }

    private func actionButton(_ title: String, _ icon: String, _ work: @escaping () -> ShellResult) -> some View {
        Button { model.action(title, work) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
    }
}
