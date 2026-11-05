// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import SwiftUI
import Charts
import IOKit

/// Lecture des propriétés d'un service IOKit (première instance de la classe).
enum IORegistry {
    static func properties(ofClass name: String) -> [String: Any]? { all(ofClass: name).first }

    static func all(ofClass name: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let s = IOIteratorNext(iterator), s != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                result.append(d)
            }
            IOObjectRelease(s)
        }
        return result
    }

    static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
    /// Valeurs signées stockées en non signé 64 bits (ex. Amperage).
    static func signed(_ v: Any?) -> Int? { (v as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) } }
}

struct BatterySnapshot: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let maxCapacity: Int     // mAh
    let design: Int
    let cycles: Int
    var health: Double { design > 0 ? Double(maxCapacity) / Double(design) * 100 : 0 }
}

struct BluetoothBattery: Identifiable {
    var id: String { name + part }
    let name: String
    let kind: String
    let part: String
    let level: Int
}

struct BatteryDetails {
    var percent = 0
    var currentMAh = 0
    var fullMAh = 0
    var nominalMAh = 0
    var designMAh = 0
    var cycles = 0
    var designCycles = 1000
    var voltage = 0.0          // V
    var amperage = 0           // mA (négatif = décharge)
    var charging = false
    var pluggedIn = false
    var fullyCharged = false
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var temperature: Double?
    var serial = ""
    var gauge = ""
    var condition = ""
    var appleMaxCapacity: Int?
    var notChargingReason = 0
    var slowChargingReason = 0
    var adapterWatts: Int?
    var adapterName = ""
    var adapterVoltage: Double?
    var adapterCurrent: Double?
    var systemWatts: Double?
    var inputWatts: Double?

    var healthMeasured: Double { designMAh > 0 ? Double(fullMAh) / Double(designMAh) * 100 : 0 }
    var watts: Double { voltage * Double(amperage) / 1000 }
}

/// Batterie détaillée (inspiré de coconutBattery, AirBattery et AlDente).
final class BatteryModel: ObservableObject {
    @Published var details: BatteryDetails?
    @Published var history: [BatterySnapshot] = []
    @Published var bluetooth: [BluetoothBattery] = []
    @Published var hasBattery = true
    private var timer: Timer?

    static let historyURL = FS.home.appendingPathComponent("Library/Application Support/BoiteAOutils/historique-batterie.json")

    init() { loadHistory() }

    func start() {
        refresh(slow: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh(slow: false) }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh(slow: Bool) {
        let previous = details
        DispatchQueue.global(qos: .userInitiated).async {
            guard var d = Self.read() else {
                DispatchQueue.main.async { self.hasBattery = false }
                return
            }
            if slow {
                Self.readProfiler(into: &d)
                let bt = Self.bluetoothBatteries()
                DispatchQueue.main.async { self.bluetooth = bt }
            } else if let p = previous {
                d.condition = p.condition
                d.appleMaxCapacity = p.appleMaxCapacity
            }
            DispatchQueue.main.async {
                self.details = d
                self.recordSnapshot(d)
            }
        }
    }

    static func read() -> BatteryDetails? {
        guard let b = IORegistry.properties(ofClass: "AppleSmartBattery") else { return nil }
        let data = b["BatteryData"] as? [String: Any] ?? [:]
        var d = BatteryDetails()
        d.percent = IORegistry.int(b["CurrentCapacity"]) ?? 0
        d.currentMAh = IORegistry.int(data["AppleRawCurrentCapacity"]) ?? IORegistry.int(b["AppleRawCurrentCapacity"]) ?? 0
        d.fullMAh = IORegistry.int(data["AppleRawMaxCapacity"]) ?? IORegistry.int(b["AppleRawMaxCapacity"]) ?? 0
        d.nominalMAh = IORegistry.int(data["NominalChargeCapacity"]) ?? IORegistry.int(b["NominalChargeCapacity"]) ?? 0
        d.designMAh = IORegistry.int(data["DesignCapacity"]) ?? IORegistry.int(b["DesignCapacity"]) ?? 0
        d.cycles = IORegistry.int(b["CycleCount"]) ?? 0
        d.designCycles = IORegistry.int(b["DesignCycleCount9C"]) ?? 1000
        d.voltage = Double(IORegistry.int(b["Voltage"]) ?? 0) / 1000
        d.amperage = IORegistry.signed(b["InstantAmperage"]) ?? IORegistry.signed(b["Amperage"]) ?? 0
        d.charging = (b["IsCharging"] as? Bool) ?? false
        d.pluggedIn = (b["ExternalConnected"] as? Bool) ?? false
        d.fullyCharged = (b["FullyCharged"] as? Bool) ?? false
        if let t = IORegistry.int(b["AvgTimeToEmpty"]), t > 0, t < 65535, !d.pluggedIn { d.minutesToEmpty = t }
        if let t = IORegistry.int(b["AvgTimeToFull"]), t > 0, t < 65535, d.charging { d.minutesToFull = t }
        d.serial = b["Serial"] as? String ?? ""
        d.gauge = b["DeviceName"] as? String ?? ""
        if let c = b["ChargerData"] as? [String: Any] {
            d.notChargingReason = IORegistry.int(c["NotChargingReason"]) ?? 0
            d.slowChargingReason = IORegistry.int(c["SlowChargingReason"]) ?? 0
        }
        if let a = b["AdapterDetails"] as? [String: Any] {
            d.adapterWatts = IORegistry.int(a["Watts"])
            d.adapterName = [a["Manufacturer"] as? String, a["Name"] as? String, a["Description"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            d.adapterVoltage = IORegistry.int(a["AdapterVoltage"]).map { Double($0) / 1000 }
            d.adapterCurrent = IORegistry.int(a["Current"]).map { Double($0) / 1000 }
        }
        // Température du SMC (l'IORegistry ne la publie plus sur les macOS récents)
        d.temperature = Sensors.batteryTemperature ?? IORegistry.int(b["Temperature"]).map { Double($0) / 100 }
        let p = Sensors.power()
        d.systemWatts = p.systemWatts
        if let w = p.inWatts, w > 0.5 { d.inputWatts = w }
        return d
    }

    private static func readProfiler(into d: inout BatteryDetails) {
        let out = Shell.exec("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]).output
        guard let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = o["SPPowerDataType"] as? [[String: Any]] else { return }
        for item in items {
            guard let h = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            d.condition = (h["sppower_battery_health"] as? String) ?? ""
            if let m = h["sppower_battery_health_maximum_capacity"] as? String { d.appleMaxCapacity = Int(m.filter(\.isNumber)) }
        }
    }

    /// Batteries des appareils Bluetooth : AirPods, souris, claviers… (inspiré d'AirBattery)
    static func bluetoothBatteries() -> [BluetoothBattery] {
        var list: [BluetoothBattery] = []
        let out = Shell.exec("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]).output
        if let data = out.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let root = (o["SPBluetoothDataType"] as? [[String: Any]])?.first,
           let connected = root["device_connected"] as? [[String: Any]] {
            let parts = [("device_batteryLevelMain", ""), ("device_batteryLevel", ""), ("device_batteryLevelLeft", "gauche"),
                         ("device_batteryLevelRight", "droite"), ("device_batteryLevelCase", "boîtier")]
            for entry in connected {
                for (name, props) in entry {
                    guard let p = props as? [String: Any] else { continue }
                    let kind = p["device_minorType"] as? String ?? ""
                    for (key, label) in parts {
                        if let s = p[key] as? String, let lvl = Int(s.filter(\.isNumber)) {
                            list.append(BluetoothBattery(name: name, kind: kind, part: label, level: lvl))
                        }
                    }
                }
            }
        }
        // Accessoires Apple (Magic Mouse, Keyboard, Trackpad) publiés dans l'IORegistry
        for d in IORegistry.all(ofClass: "AppleDeviceManagementHIDEventService") + IORegistry.all(ofClass: "IOHIDDevice") {
            if let lvl = IORegistry.int(d["BatteryPercent"]), let name = d["Product"] as? String,
               !list.contains(where: { $0.name == name }) {
                list.append(BluetoothBattery(name: name, kind: "Accessoire", part: "", level: lvl))
            }
        }
        return list
    }

    // MARK: Historique de santé (enregistré au plus une fois par jour)

    private func loadHistory() {
        if let d = try? Data(contentsOf: Self.historyURL),
           let h = try? JSONDecoder().decode([BatterySnapshot].self, from: d) { history = h }
    }

    private func recordSnapshot(_ d: BatteryDetails) {
        guard d.fullMAh > 0, d.designMAh > 0 else { return }
        if let last = history.last, Calendar.current.isDate(last.date, inSameDayAs: Date()) { return }
        history.append(BatterySnapshot(date: Date(), maxCapacity: d.fullMAh, design: d.designMAh, cycles: d.cycles))
        try? FS.fm.createDirectory(at: Self.historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: Self.historyURL) }
    }
}

struct BatteryView: View {
    @ObservedObject var model: BatteryModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Batterie", subtitle: "Santé, usure, charge et appareils Bluetooth",
                           icon: "battery.100.bolt", color: .green) {
                    Button("Réglages Batterie…") {
                        Permissions.openSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension")
                    }
                }
                Group {
                    if let d = model.details {
                        overview(d)
                        HStack(alignment: .top, spacing: 16) {
                            health(d)
                            charge(d)
                        }
                        historyCard
                        technical(d)
                    } else if !model.hasBattery {
                        Card { Label("Ce Mac n'a pas de batterie interne.", systemImage: "powerplug") }
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                    bluetoothCard
                    Card(title: "Limiter la charge (façon AlDente)", icon: "bolt.badge.clock") {
                        Text("macOS sait limiter lui-même la charge pour préserver la batterie (« Recharge optimisée » et, sur les macOS récents, une limite de charge réglable). C'est la méthode la plus sûre, sans outil tiers.")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Ouvrir les réglages de charge…") {
                            Permissions.openSettings("x-apple.systempreferences:com.apple.Battery-Settings.extension")
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private func overview(_ d: BatteryDetails) -> some View {
        Card {
            HStack(spacing: 24) {
                Ring(value: Double(d.percent) / 100, color: d.percent < 20 ? .red : .green)
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusText(d)).font(.title3.bold())
                    if let m = d.minutesToEmpty { Text("Autonomie estimée : \(duration(m))").foregroundStyle(.secondary) }
                    if let m = d.minutesToFull { Text("Charge complète dans : \(duration(m))").foregroundStyle(.secondary) }
                    Text("\(d.currentMAh) mAh sur \(d.fullMAh) mAh").foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    stat(String(format: "%+.1f W", d.watts), d.watts >= 0 ? "Entrée batterie" : "Sortie batterie")
                    if let t = d.temperature { stat(String(format: "%.1f °C", t), "Température") }
                    if let s = d.systemWatts { stat(String(format: "%.1f W", s), "Consommation du Mac") }
                }
            }
        }
    }

    private func health(_ d: BatteryDetails) -> some View {
        Card(title: "Santé", icon: "heart.fill") {
            row("État (macOS)", d.condition.isEmpty ? "—" : (d.condition == "Good" ? "Normal" : d.condition))
            row("Capacité maximale (Apple)", d.appleMaxCapacity.map { "\($0) %" } ?? "—")
            row("Capacité réelle mesurée", String(format: "%.1f %%", d.healthMeasured))
            ProgressView(value: min(d.healthMeasured / 100, 1)).tint(d.healthMeasured < 80 ? .orange : .green)
            row("Capacité d'origine", "\(d.designMAh) mAh")
            row("Capacité à pleine charge", "\(d.fullMAh) mAh")
            row("Cycles de charge", "\(d.cycles) / \(d.designCycles)")
            ProgressView(value: min(Double(d.cycles) / Double(max(d.designCycles, 1)), 1)).tint(.blue)
            Text(verdict(d)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func charge(_ d: BatteryDetails) -> some View {
        Card(title: "Alimentation", icon: "powerplug.fill") {
            row("Chargeur", d.pluggedIn ? "Branché" : "Débranché")
            if d.pluggedIn {
                if let w = d.adapterWatts { row("Puissance du chargeur", "\(w) W") }
                if !d.adapterName.isEmpty { row("Modèle", d.adapterName) }
                if let v = d.adapterVoltage, let a = d.adapterCurrent { row("Tension / courant négociés", String(format: "%.1f V · %.2f A", v, a)) }
                if let w = d.inputWatts { row("Puissance reçue (mesurée)", String(format: "%.1f W", w)) }
                row("En charge", d.charging ? "Oui" : (d.fullyCharged ? "Non (pleine)" : "Non (en pause)"))
                if !d.charging && !d.fullyCharged {
                    Text("La charge peut être suspendue par la recharge optimisée, une limite de charge ou une température élevée.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if d.slowChargingReason != 0 {
                    Label("Charge ralentie par macOS (code \(d.slowChargingReason)) : chargeur ou câble trop faible, ou chaleur.",
                          systemImage: "tortoise.fill").font(.callout).foregroundStyle(.orange)
                }
            } else {
                Text("Branchez un chargeur pour voir sa puissance, la tension négociée et le détail dans « Câbles & ports ».")
                    .font(.callout).foregroundStyle(.secondary)
            }
            row("Tension batterie", String(format: "%.2f V", d.voltage))
            row("Courant", "\(d.amperage) mA")
        }
    }

    private var historyCard: some View {
        Card(title: "Historique de santé", icon: "chart.xyaxis.line") {
            if model.history.count < 2 {
                Text("La capacité est enregistrée une fois par jour quand la Boîte à outils est ouverte. La courbe apparaîtra dès le deuxième relevé.")
                    .foregroundStyle(.secondary)
            } else {
                Chart(model.history) { s in
                    LineMark(x: .value("Date", s.date), y: .value("Santé", s.health)).interpolationMethod(.monotone)
                    PointMark(x: .value("Date", s.date), y: .value("Santé", s.health)).symbolSize(20)
                }
                .chartYScale(domain: max(0, (model.history.map(\.health).min() ?? 80) - 5)...100)
                .chartYAxisLabel("% de la capacité d'origine")
                .frame(height: 160)
            }
        }
    }

    private func technical(_ d: BatteryDetails) -> some View {
        Card(title: "Informations techniques", icon: "info.circle") {
            row("Numéro de série", d.serial.isEmpty ? "—" : d.serial)
            row("Contrôleur de jauge", d.gauge.isEmpty ? "—" : d.gauge)
            row("Capacité nominale", "\(d.nominalMAh) mAh")
            row("Énergie stockée", String(format: "%.1f Wh", Double(d.currentMAh) * d.voltage / 1000))
        }
    }

    private var bluetoothCard: some View {
        Card(title: "Appareils Bluetooth", icon: "airpodspro") {
            if model.bluetooth.isEmpty {
                Text("Aucune batterie d'appareil connecté détectée (AirPods, souris, clavier…).").foregroundStyle(.secondary)
            }
            ForEach(model.bluetooth) { b in
                HStack {
                    Image(systemName: icon(b.kind)).frame(width: 22)
                    Text(b.name + (b.part.isEmpty ? "" : " (\(b.part))"))
                    Spacer()
                    ProgressView(value: Double(b.level) / 100).frame(width: 120).tint(b.level < 20 ? .red : .green)
                    Text("\(b.level) %").monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            Text("L'iPhone ou l'iPad branché en USB n'est pas lisible ici (protocole réservé à Apple et à coconutBattery).")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case let k where k.contains("headphone") || k.contains("headset"): "airpodspro"
        case let k where k.contains("mouse"): "computermouse"
        case let k where k.contains("keyboard"): "keyboard"
        case let k where k.contains("gamepad"): "gamecontroller"
        case let k where k.contains("speaker"): "hifispeaker"
        default: "dot.radiowaves.left.and.right"
        }
    }

    private func statusText(_ d: BatteryDetails) -> String {
        if d.charging { return "En charge" }
        if d.pluggedIn { return d.fullyCharged ? "Chargée, sur secteur" : "Sur secteur (charge en pause)" }
        return "Sur batterie"
    }

    private func verdict(_ d: BatteryDetails) -> String {
        let h = Double(d.appleMaxCapacity ?? Int(d.healthMeasured))
        let wear = Double(d.cycles) / Double(max(d.designCycles, 1)) * 100
        let base = h >= 90 ? "Batterie en très bon état." : h >= 80 ? "Usure normale : la batterie fonctionne correctement." :
                   "Capacité inférieure à 80 % : Apple considère qu'un remplacement peut être envisagé."
        return base + String(format: " Environ %.0f %% de la durée de vie prévue en cycles a été utilisée.", wear)
    }

    private func duration(_ m: Int) -> String { m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min" }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).monospacedDigit().textSelection(.enabled) }
    }

    private func stat(_ v: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
