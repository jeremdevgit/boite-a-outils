// swift-tools-version:5.10
// SPDX-License-Identifier: GPL-3.0-or-later — Copyright (C) 2026 jeremdevgit
// Swift Package entry point for native code analysis. Distributable bundles
// and translations are still assembled by macos/build.sh.
import PackageDescription

let package = Package(
    name: "BoiteAOutils",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "BoiteAOutils", path: "macos/Sources")]
)
