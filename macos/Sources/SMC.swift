// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit — voir LICENSE
import Foundation
import IOKit

// Lecture du SMC (contrôleur de gestion système) : températures, ventilateurs, puissance.
// Structures ABI reprises de WhatCable (MIT, © 2026 Darryl Morley) et de smcFanControl.

struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimit = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0          // rétablit l'alignement C : la structure doit faire 80 octets
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCValue {
    let type: String
    let bytes: [UInt8]

    /// Valeur numérique selon le type SMC.
    var number: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32": return bytes.count >= 4 ? Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) : nil
        default: return nil
        }
    }
}

final class SMC {
    static let shared = SMC()
    private var connection: io_connect_t = 0
    private let lock = NSLock()

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
    }

    var available: Bool { connection != 0 }

    static func fourCC(_ s: String) -> UInt32 { s.unicodeScalars.prefix(4).reduce(0) { $0 << 8 | ($1.value & 0xFF) } }
    static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }, encoding: .isoLatin1) ?? "????"
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard connection != 0 else { return nil }
        var output = SMCParamStruct()
        var size = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.stride, &output, &size)
        return kr == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    func read(_ key: String) -> SMCValue? {
        lock.lock(); defer { lock.unlock() }
        var info = SMCParamStruct()
        info.key = Self.fourCC(key)
        info.data8 = 9                                  // lire les infos de la clé
        guard let infoOut = call(&info), infoOut.keyInfo.dataSize > 0 else { return nil }
        var req = SMCParamStruct()
        req.key = info.key
        req.keyInfo.dataSize = infoOut.keyInfo.dataSize
        req.data8 = 5                                   // lire la valeur
        guard var out = call(&req) else { return nil }
        let count = Int(min(infoOut.keyInfo.dataSize, 32))
        let bytes = withUnsafeBytes(of: &out.bytes) { Array($0.prefix(count)) }
        return SMCValue(type: Self.string(infoOut.keyInfo.dataType), bytes: bytes)
    }

    func number(_ key: String) -> Double? { read(key)?.number }

    /// Toutes les clés du SMC (énumération par index).
    func allKeys() -> [String] {
        guard let n = number("#KEY"), n > 0 else { return [] }
        var keys: [String] = []
        lock.lock(); defer { lock.unlock() }
        for i in 0..<Int(n) {
            var p = SMCParamStruct()
            p.data8 = 8                                 // clé à partir de l'index
            p.data32 = UInt32(i)
            if let out = call(&p) { keys.append(Self.string(out.key)) }
        }
        return keys
    }
}

// MARK: - Capteurs

struct SensorReading: Identifiable {
    var id: String { key }
    let key: String
    let group: String
    let value: Double
}

enum Sensors {
    /// Clés de température valides sur ce Mac (calculé une fois).
    static let temperatureKeys: [String] = {
        SMC.shared.allKeys().filter { k in
            guard k.hasPrefix("T"), let v = SMC.shared.read(k), v.type == "flt " || v.type == "sp78",
                  let n = v.number else { return false }
            return n > 5 && n < 130
        }
    }()

    static func group(_ key: String) -> String {
        let p2 = String(key.prefix(2)), p3 = String(key.prefix(3))
        if key.hasPrefix("TB") { return "Batterie" }
        if p2 == "Tp" || p2 == "TC" { return "Processeur (cœurs performance)" }
        if p2 == "Te" { return "Processeur (cœurs efficacité)" }
        if p2 == "Tg" || p2 == "TG" { return "Carte graphique (GPU)" }
        if p2 == "Tm" || p2 == "TM" { return "Mémoire" }
        if p2 == "TH" || p3 == "TS0" || p2 == "TN" { return "Stockage (SSD)" }
        if p2 == "TW" { return "Wi-Fi / Bluetooth" }
        if p2 == "Ta" || p2 == "TA" { return "Air / ambiant" }
        if p2 == "Ts" || p2 == "TP" { return "Boîtier et alimentation" }
        return "Autres capteurs"
    }

    static func readAll() -> [SensorReading] {
        temperatureKeys.compactMap { k in
            SMC.shared.number(k).map { SensorReading(key: k, group: group(k), value: $0) }
        }
    }

    static var batteryTemperature: Double? {
        let v = temperatureKeys.filter { $0.hasPrefix("TB") }.compactMap { SMC.shared.number($0) }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }

    struct Fan: Identifiable { let id: Int; let rpm: Double; let min: Double; let max: Double }

    static func fans() -> [Fan] {
        let n = Int(SMC.shared.number("FNum") ?? 0)
        return (0..<n).compactMap { i in
            guard let rpm = SMC.shared.number("F\(i)Ac") else { return nil }
            return Fan(id: i, rpm: rpm, min: SMC.shared.number("F\(i)Mn") ?? 0, max: SMC.shared.number("F\(i)Mx") ?? 0)
        }
    }

    /// Puissance en entrée (chargeur) et consommation système, en watts.
    struct Power { var inVolts: Double?; var inAmps: Double?; var inWatts: Double?; var systemWatts: Double?; var batteryWatts: Double? }

    static func power() -> Power {
        let v = SMC.shared.number("VD0R"), a = SMC.shared.number("ID0R")
        var p = Power(inVolts: v, inAmps: a)
        p.inWatts = SMC.shared.number("PDTR") ?? (v != nil && a != nil ? v! * a! : nil)
        p.systemWatts = SMC.shared.number("PSTR")
        if let b = SMC.shared.number("PPBR"), b >= 0, b < 200 { p.batteryWatts = b }
        return p
    }
}
