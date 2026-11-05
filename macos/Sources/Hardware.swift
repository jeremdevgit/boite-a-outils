// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI

// MARK: - Capteurs (inspiré de Macs Fan Control / Stats)

enum GPU {
    static var utilization: Double? {
        for d in IORegistry.all(ofClass: "IOAccelerator") {
            if let s = d["PerformanceStatistics"] as? [String: Any], let u = IORegistry.int(s["Device Utilization %"]) { return Double(u) }
        }
        return nil
    }
}

final class SensorsModel: ObservableObject {
    @Published var readings: [SensorReading] = []
    @Published var fans: [Sensors.Fan] = []
    @Published var power = Sensors.Power()
    @Published var gpu: Double?
    private var timer: Timer?

    var groups: [(name: String, max: Double, avg: Double, items: [SensorReading])] {
        let grouped = Dictionary(grouping: readings, by: \.group)
        var result: [(name: String, max: Double, avg: Double, items: [SensorReading])] = []
        for (k, v) in grouped {
            let values = v.map(\.value)
            let avg = values.reduce(0, +) / Double(values.count)
            result.append((name: k, max: values.max() ?? 0, avg: avg, items: v.sorted { $0.key < $1.key }))
        }
        return result.sorted { $0.max > $1.max }
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Sensors.readAll(), f = Sensors.fans(), p = Sensors.power(), g = GPU.utilization
            DispatchQueue.main.async { self.readings = r; self.fans = f; self.power = p; self.gpu = g }
        }
    }
}

struct SensorsView: View {
    @ObservedObject var model: SensorsModel
    @Local private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Capteurs", subtitle: "Températures, ventilateurs, consommation et GPU en direct",
                           icon: "thermometer.medium", color: .red)
                Group {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        if let s = model.power.systemWatts { tile(String(format: "%.1f W", s), "Consommation totale", "bolt.fill") }
                        if let g = model.gpu { tile("\(Int(g)) %", "Utilisation GPU", "cpu.fill") }
                        if let hot = model.readings.max(by: { $0.value < $1.value }) {
                            tile(String(format: "%.0f °C", hot.value), "Capteur le plus chaud", "flame.fill")
                        }
                        ForEach(model.fans) { f in
                            tile("\(Int(f.rpm)) tr/min", "Ventilateur \(f.id + 1) (\(Int(f.min))–\(Int(f.max)))", "fan.fill")
                        }
                    }
                    if model.fans.isEmpty {
                        Text("Ce Mac n'a pas de ventilateur (refroidissement passif) ou ils ne sont pas exposés.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.groups, id: \.name) { g in
                        Card {
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(g.name) },
                                                                set: { if $0 { expanded.insert(g.name) } else { expanded.remove(g.name) } })) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], alignment: .leading, spacing: 6) {
                                    ForEach(g.items) { r in
                                        Text("\(r.key)  \(String(format: "%.1f °C", r.value))")
                                            .font(.system(.caption, design: .monospaced)).foregroundStyle(color(r.value))
                                    }
                                }
                                .padding(.top, 6)
                            } label: {
                                HStack {
                                    Text(g.name).bold()
                                    Text("\(g.items.count) capteurs").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "moy. %.0f °C", g.avg)).foregroundStyle(.secondary).monospacedDigit()
                                    Text(String(format: "max %.0f °C", g.max)).bold().monospacedDigit().foregroundStyle(color(g.max))
                                        .frame(width: 90, alignment: .trailing)
                                }
                            }
                        }
                    }
                    Text("Lecture seule : le pilotage des ventilateurs exige un service système privilégié et peut endommager le Mac en cas d'erreur.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func color(_ t: Double) -> Color { t > 90 ? .red : t > 75 ? .orange : .primary }

    private func tile(_ v: String, _ l: String, _ icon: String) -> some View {
        Card {
            Label(l, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title2.bold().monospacedDigit())
        }
    }
}

// MARK: - Disques (inspiré de DriveDx et Blackmagic Disk Speed Test)

struct PhysicalDisk: Identifiable {
    var id: String { bsd }
    let bsd: String
    let name: String
    let size: Int64
    let smart: String
    let solidState: Bool
    let internalDisk: Bool
    let protocolName: String
    let trim: String?
}

struct VolumeInfo: Identifiable {
    var id: URL { url }
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    let format: String
    let internalVolume: Bool
    let writable: Bool
}

final class DisksModel: ObservableObject {
    @Published var disks: [PhysicalDisk] = []
    @Published var volumes: [VolumeInfo] = []
    @Published var testVolume: URL?
    @Published var testSizeMB = 1024
    @Published var testing = false
    @Published var progress = ""
    @Published var write: Double?
    @Published var read: Double?
    var cancelled = false

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            var disks: [PhysicalDisk] = []
            let nvme = Shell.exec("/usr/sbin/system_profiler", ["SPNVMeDataType", "-json"]).output
            if let plist = Shell.exec("/usr/sbin/diskutil", ["list", "-plist", "physical"]).output.data(using: .utf8),
               let d = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
               let whole = d["WholeDisks"] as? [String] {
                for w in whole {
                    guard let data = Shell.exec("/usr/sbin/diskutil", ["info", "-plist", w]).output.data(using: .utf8),
                          let i = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                    disks.append(PhysicalDisk(
                        bsd: w, name: i["MediaName"] as? String ?? w, size: (i["TotalSize"] as? NSNumber)?.int64Value ?? 0,
                        smart: i["SMARTStatus"] as? String ?? "Non pris en charge", solidState: i["SolidState"] as? Bool ?? false,
                        internalDisk: i["Internal"] as? Bool ?? false, protocolName: i["BusProtocol"] as? String ?? "",
                        trim: nvme.contains("\"\(w)\"") ? (nvme.contains("\"spnvme_trim_support\" : \"Yes\"") ? "Oui" : "Non") : nil))
                }
            }
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                          .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsInternalKey,
                                          .volumeIsReadOnlyKey, .volumeIsBrowsableKey]
            let vols = (FS.fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []).compactMap { u -> VolumeInfo? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { return nil }
                return VolumeInfo(url: u, name: v.volumeName ?? u.lastPathComponent, total: Int64(v.volumeTotalCapacity ?? 0),
                                  free: v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0),
                                  format: v.volumeLocalizedFormatDescription ?? "", internalVolume: v.volumeIsInternal ?? false,
                                  writable: !(v.volumeIsReadOnly ?? false))
            }
            DispatchQueue.main.async {
                self.disks = disks
                self.volumes = vols
                if self.testVolume == nil { self.testVolume = vols.first { $0.url.path == "/" }?.url ?? vols.first?.url }
            }
        }
    }

    /// Écrit puis relit un fichier sans cache disque pour mesurer le débit réel.
    func speedTest() {
        guard let vol = testVolume else { return }
        cancelled = false
        testing = true
        write = nil
        read = nil
        let total = testSizeMB
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = vol.path == "/" ? FS.fm.temporaryDirectory : vol
            let file = dir.appendingPathComponent(".boiteaoutils-speedtest-\(UUID().uuidString)")
            defer { unlink(file.path) }
            let chunk = 8 * 1024 * 1024
            var buffer = [UInt8](repeating: 0, count: chunk)
            for i in stride(from: 0, to: chunk, by: 4096) { buffer[i] = UInt8.random(in: 0...255) }
            let chunks = total * 1024 * 1024 / chunk

            let fd = open(file.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
            guard fd >= 0 else {
                DispatchQueue.main.async { self.testing = false; self.progress = "Impossible d'écrire sur ce volume." }
                return
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            var t0 = Date()
            for i in 0..<chunks {
                if self.cancelled { break }
                _ = buffer.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, chunk) }
                if i % 8 == 0 { let p = i * 100 / chunks; DispatchQueue.main.async { self.progress = "Écriture… \(p) %" } }
            }
            fsync(fd)
            close(fd)
            let w = Double(total) / Date().timeIntervalSince(t0)

            let rfd = open(file.path, O_RDONLY)
            _ = fcntl(rfd, F_NOCACHE, 1)
            t0 = Date()
            var readBytes = 0
            while !self.cancelled {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(rfd, $0.baseAddress, chunk) }
                if n <= 0 { break }
                readBytes += n
                if (readBytes / chunk) % 8 == 0 { let p = readBytes * 100 / max(total * 1024 * 1024, 1); DispatchQueue.main.async { self.progress = "Lecture… \(p) %" } }
            }
            close(rfd)
            let r = Double(readBytes) / 1_048_576 / Date().timeIntervalSince(t0)
            DispatchQueue.main.async {
                self.testing = false
                self.progress = ""
                if !self.cancelled { self.write = w; self.read = r }
            }
        }
    }

    static func interpretation(_ mbps: Double) -> String {
        switch mbps {
        case ..<45: "Équivalent USB 2.0 : câble, port ou adaptateur probablement limitant (voir « Câbles & ports »)."
        case ..<200: "Disque dur ou clé USB classique."
        case ..<500: "Niveau USB 3 (5 Gb/s) ou SSD SATA."
        case ..<1100: "Niveau USB 3.2 Gen 2 (10 Gb/s)."
        case ..<3000: "SSD NVMe rapide ou Thunderbolt/USB4."
        default: "Très haut débit (SSD interne Apple, Thunderbolt 4/5)."
        }
    }
}

struct DisksView: View {
    @ObservedObject var model: DisksModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Disques", subtitle: "Santé SMART, volumes et test de vitesse réel",
                           icon: "internaldrive.fill", color: .indigo) {
                    Button { model.load() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                    Button("Utilitaire de disque") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app")) }
                }
                Group {
                    ForEach(model.disks) { d in
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: d.internalDisk ? "internaldrive.fill" : "externaldrive.fill").font(.title)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.name).font(.headline)
                                    Text("\(formatBytes(d.size)) · \(d.solidState ? "SSD" : "Disque dur") · \(d.protocolName) · \(d.bsd)")
                                        .foregroundStyle(.secondary)
                                    if let t = d.trim { Text("TRIM : \(t)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                let ok = d.smart == "Verified"
                                Label(ok ? "SMART : bon état" : "SMART : \(d.smart)",
                                      systemImage: ok ? "checkmark.seal.fill" : (d.smart == "Failing" ? "xmark.octagon.fill" : "questionmark.circle"))
                                    .foregroundStyle(ok ? .green : (d.smart == "Failing" ? .red : .secondary)).bold()
                            }
                        }
                    }
                    Card(title: "Volumes", icon: "square.stack.3d.up") {
                        ForEach(model.volumes) { v in
                            HStack {
                                Text(v.name).frame(width: 180, alignment: .leading)
                                ProgressView(value: v.total > 0 ? Double(v.total - v.free) / Double(v.total) : 0).frame(maxWidth: 220)
                                Text("\(formatBytes(v.free)) libres sur \(formatBytes(v.total))").font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Text(v.format).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Card(title: "Test de vitesse", icon: "speedometer") {
                        HStack {
                            Picker("Volume", selection: $model.testVolume) {
                                ForEach(model.volumes.filter(\.writable)) { Text($0.name).tag(Optional($0.url)) }
                            }.frame(maxWidth: 300)
                            Picker("Taille", selection: $model.testSizeMB) {
                                Text("256 Mo").tag(256); Text("1 Go").tag(1024); Text("4 Go").tag(4096)
                            }.frame(width: 160)
                            Spacer()
                            if model.testing {
                                Text(model.progress).monospacedDigit().foregroundStyle(.secondary)
                                Button("Arrêter") { model.cancelled = true }
                            } else {
                                Button("Lancer le test") { model.speedTest() }.buttonStyle(.borderedProminent)
                            }
                        }
                        if let w = model.write, let r = model.read {
                            HStack(spacing: 30) {
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.0f Mo/s", w)).font(.title.bold().monospacedDigit())
                                    Text("Écriture").foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.0f Mo/s", r)).font(.title.bold().monospacedDigit())
                                    Text("Lecture").foregroundStyle(.secondary)
                                }
                            }
                            Label(DisksModel.interpretation(min(w, r)), systemImage: "info.circle").foregroundStyle(.secondary)
                        }
                        Text("Un fichier temporaire est écrit puis relu sans cache, puis supprimé.").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { if model.disks.isEmpty { model.load() } }
    }
}

// MARK: - Écrans (inspiré de BetterDisplay)

struct DisplayModeInfo: Identifiable, Hashable {
    var id: String { "\(width)x\(height)@\(pixelWidth)@\(refresh)" }
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refresh: Double
    let mode: CGDisplayMode
    var hiDPI: Bool { pixelWidth > width }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let builtIn: Bool
    let main: Bool
    let current: DisplayModeInfo?
    let modes: [DisplayModeInfo]
    let sizeMM: CGSize
    let vendor: UInt32
    let model: UInt32

    var diagonalInches: Double { sqrt(pow(sizeMM.width, 2) + pow(sizeMM.height, 2)) / 25.4 }
    var ppi: Double? {
        guard let c = current, sizeMM.width > 0 else { return nil }
        return Double(c.pixelWidth) / (sizeMM.width / 25.4)
    }
}

final class DisplaysModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var gpu = ""
    @Published var pendingRevert: (CGDirectDisplayID, CGDisplayMode)?
    @Published var countdown = 0
    private var timer: Timer?

    func load() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        displays = ids.prefix(Int(count)).map { id in
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let all = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            var seen = Set<String>()
            let usable = all.filter { $0.isUsableForDesktopGUI() }.map(Self.info)
            let unique = usable.filter { seen.insert($0.id).inserted }
            let modes = unique.sorted { a, b in
                if a.width != b.width { return a.width > b.width }
                if a.hiDPI != b.hiDPI { return a.hiDPI }
                return a.refresh > b.refresh
            }
            return DisplayInfo(id: id, name: screen?.localizedName ?? "Écran \(id)", builtIn: CGDisplayIsBuiltin(id) != 0,
                               main: CGDisplayIsMain(id) != 0, current: CGDisplayCopyDisplayMode(id).map(Self.info), modes: modes,
                               sizeMM: CGDisplayScreenSize(id), vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
        }
        DispatchQueue.global(qos: .utility).async {
            let out = Shell.exec("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"]).output
            var text = ""
            if let d = out.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let g = (o["SPDisplaysDataType"] as? [[String: Any]])?.first {
                text = [g["sppci_model"] as? String, (g["sppci_cores"] as? String).map { "\($0) cœurs GPU" },
                        (g["spdisplays_mtlgpufamilysupport"] as? String)?.replacingOccurrences(of: "spdisplays_", with: "")]
                    .compactMap { $0 }.joined(separator: " · ")
            }
            DispatchQueue.main.async { self.gpu = text }
        }
    }

    static func info(_ m: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(width: m.width, height: m.height, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight, refresh: m.refreshRate, mode: m)
    }

    /// Change de résolution ; sans confirmation sous 15 s, l'ancienne est rétablie (comme macOS).
    func apply(_ mode: DisplayModeInfo, on display: DisplayInfo) {
        guard let previous = CGDisplayCopyDisplayMode(display.id) else { return }
        set(mode.mode, on: display.id)
        pendingRevert = (display.id, previous)
        countdown = 15
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countdown -= 1
            if self.countdown <= 0 { self.revert() }
        }
        load()
    }

    func keep() {
        timer?.invalidate()
        pendingRevert = nil
    }

    func revert() {
        timer?.invalidate()
        if let (id, m) = pendingRevert { set(m, on: id) }
        pendingRevert = nil
        load()
    }

    private func set(_ mode: CGDisplayMode, on id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        CGCompleteDisplayConfiguration(config, .permanently)
    }
}

struct DisplaysView: View {
    @ObservedObject var model: DisplaysModel
    @Local private var showAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Écrans", subtitle: "Résolutions (y compris HiDPI cachées), fréquence, taille réelle",
                           icon: "display.2", color: .cyan) {
                    Toggle("Afficher toutes les résolutions", isOn: $showAll).toggleStyle(.checkbox)
                    Button { model.load() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
                }
                Group {
                    if model.pendingRevert != nil {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Conserver cette résolution ? Retour automatique dans \(model.countdown) s.").bold()
                            Spacer()
                            Button("Rétablir") { model.revert() }
                            Button("Conserver") { model.keep() }.buttonStyle(.borderedProminent)
                        }
                        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.15)))
                    }
                    if !model.gpu.isEmpty { Label(model.gpu, systemImage: "cpu").foregroundStyle(.secondary) }
                    ForEach(model.displays) { d in displayCard(d) }
                    Text("Le réglage de la luminosité des écrans externes (DDC, façon MonitorControl) passe par des interfaces non documentées d'Apple : il n'est pas inclus pour éviter tout risque.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { model.load() }
    }

    private func displayCard(_ d: DisplayInfo) -> some View {
        Card {
            HStack {
                Image(systemName: d.builtIn ? "laptopcomputer" : "display").font(.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name + (d.main ? " (principal)" : "")).font(.headline)
                    if let c = d.current {
                        Text("\(c.width) × \(c.height)\(c.hiDPI ? " HiDPI" : "") · \(c.pixelWidth) × \(c.pixelHeight) pixels · \(c.refresh > 0 ? "\(Int(c.refresh.rounded())) Hz" : "fréquence variable")")
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: "%.1f pouces", d.diagonalInches) + (d.ppi.map { String(format: " · %.0f ppp", $0) } ?? "") +
                         String(format: " · fabricant 0x%04X, modèle 0x%04X", d.vendor, d.model))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            let modes = showAll ? d.modes : d.modes.filter { $0.hiDPI || d.modes.allSatisfy { !$0.hiDPI } }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                ForEach(modes) { m in
                    let current = d.current?.id == m.id
                    Button { model.apply(m, on: d) } label: {
                        HStack {
                            Text("\(m.width) × \(m.height)").monospacedDigit()
                            if m.hiDPI { Text("HiDPI").font(.caption2.bold()).foregroundStyle(.cyan) }
                            if m.refresh > 0 { Text("\(Int(m.refresh.rounded())) Hz").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if current { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(current)
                }
            }
        }
    }
}
