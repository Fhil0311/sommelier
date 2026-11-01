// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// What the service hands every app that can change what runs on a Mac (the fixes and recipes lists, the engine
/// list, shared shaders) is signed on the owner's Mac with the key that signs app updates (Ed25519,
/// `scripts/update-signing-key.swift sign`). The app checks it against the public half it carries (`SUPublicEDKey`):
/// someone who takes over the service, its storage or its owner's token can't hand players anything of their own.
public enum Signature {
    /// The response header the signature (base64) comes in.
    public static let header = "X-Sommelier-Signature"

    /// The public key: the app's own (Info.plist `SUPublicEDKey`), or one set for tests.
    nonisolated(unsafe) public static var publicKey: Curve25519.Signing.PublicKey? = {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let raw = Data(base64Encoded: text) else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }()

    /// A release build takes nothing unsigned. A debug build also takes unsigned data (the services running on this
    /// Mac don't sign), but a signature that is there must still be right.
    nonisolated(unsafe) public static var required: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOMMELIER_REQUIRE_SIGNATURES"] == "1"
        #else
        true
        #endif
    }()

    /// Whether `signature` (base64) is the key's signature of exactly `data`.
    public static func isValid(_ signature: String?, for data: Data) -> Bool {
        guard let signature, let bytes = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = publicKey else { return false }
        return key.isValidSignature(bytes, for: data)
    }

    /// Whether to use `data`: signed rightly, or unsigned where unsigned is allowed (debug builds).
    public static func accepts(_ data: Data, signature: String?) -> Bool {
        if let signature, !signature.isEmpty { return isValid(signature, for: data) }
        return !required
    }

    /// The signature header of a response.
    public static func of(_ response: URLResponse?) -> String? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: header)
    }
}
