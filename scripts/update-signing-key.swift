// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
// The key that signs app updates (Sparkle's EdDSA, Ed25519). The private half lives in the login keychain, as a
// generic password "Sommelier update signing" / "ed25519"; the app carries the public half (SUPublicEDKey).
//
//   swift scripts/update-signing-key.swift create     makes the key once (refuses if one exists), prints the public key
//   swift scripts/update-signing-key.swift public     prints the public key
//   swift scripts/update-signing-key.swift sign FILE  prints the base64 signature of FILE (sparkle:edSignature)
//
// Back up the private key (Keychain Access → "Sommelier update signing" → Show Password): without it no update can
// ever be published to people who installed a build carrying the public key.
import CryptoKit
import Foundation

let service = "Sommelier update signing", account = "ed25519"

func run(_ args: [String]) -> (Int32, String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try! p.run(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

func storedKey() -> Curve25519.Signing.PrivateKey? {
    let (status, value) = run(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard status == 0, let raw = Data(base64Encoded: value) else { return nil }
    return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
}

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "create":
    if storedKey() != nil { fail("A key already exists; not replacing it.") }
    let key = Curve25519.Signing.PrivateKey()
    let (status, _) = run(["add-generic-password", "-s", service, "-a", account, "-w", key.rawRepresentation.base64EncodedString(),
                           "-l", service, "-j", "Signs Sommelier app updates (Sparkle EdDSA). Back this up."])
    if status != 0 { fail("Couldn't store the key in the keychain.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    guard let key = storedKey() else { fail("No key yet: run create.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let key = storedKey() else { fail("No key yet: run create.") }
    guard let path = args.dropFirst().first, let data = FileManager.default.contents(atPath: path) else { fail("sign FILE") }
    print(try! key.signature(for: data).base64EncodedString())
default:
    fail("usage: create | public | sign FILE")
}
