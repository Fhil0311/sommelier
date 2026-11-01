// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation
import Testing
@testable import SommelierKit

@Suite struct PrivacyScrubTests {
    let names = ["ivanov", "Ivan Petrov", "Ivan", "Petrov", "Ivan's MacBook Pro"]

    @Test func wineAndMacPathsInEveryForm() {
        let lines = [
            #"err:module:load_dll C:\\users\\ivanov\\AppData\\Local\\Game\\x.dll"#,     // Wine doubles its backslashes
            #"C:\users\ivanov\Documents\My Games"#,
            #"c:/Users/ivanov/AppData"#,
            #"Z:\\Users\\ivanov\\Library"#,
            #""path":"\/Users\/ivanov\/Library\/Application Support""#,             // a crash report's JSON
            "/Users/ivanov/Library/Logs/x.log",
            "/Volumes/Ivan SSD/Games/Raft/Raft.exe",
            #""\/Volumes\/Work\/SteamLibrary""#,
        ]
        for line in lines {
            let out = DiagnosticsCollector.scrub(line, names: [])
            #expect(!out.localizedCaseInsensitiveContains("ivanov"), "\(line) → \(out)")
            #expect(!out.contains("Ivan SSD") && !out.contains("Work"), "\(line) → \(out)")
        }
        #expect(DiagnosticsCollector.scrub(#"C:\\users\\ivanov\\AppData"#, names: []) == #"C:\\users\\…\\AppData"#)
    }

    @Test func namesGoAsWholeWordsOnly() {
        let out = DiagnosticsCollector.scrub("Ivan Petrov on Ivan's MacBook Pro set MaxFPS for ivanov", names: names)
        #expect(!out.contains("Ivan") && !out.contains("Petrov") && !out.contains("ivanov"))
        #expect(DiagnosticsCollector.scrub("MaxFPS=60", names: ["max"]) == "MaxFPS=60")
    }

    @Test func accountsAndTokens() {
        let out = DiagnosticsCollector.scrub(#"-epicusername="Ivan" -epicuserid=abc123 [U:1:12345] {"access_token": "eyJhbGciOi"}"#, names: [])
        #expect(!out.contains("abc123") && !out.contains("12345") && !out.contains("eyJ"))
    }

    @Test func crashReportKeepsOnlyWhatHelps() throws {
        let header = #"{"app_name":"wine-preloader","os_version":"macOS 15.6 (24G84)","bug_type":"309","crashReporterKey":"SECRET-KEY"}"#
        let body = #"""
        {"procName":"wine-preloader","procPath":"\/Users\/ivanov\/Library\/x","userID":501,"crashReporterKey":"SECRET-KEY",
         "deviceIdentifierForVendor":"DEVICE-ID","bootSessionUUID":"BOOT-ID","faultingThread":0,
         "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x0"},
         "threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"wined3d_device_create"},{"imageIndex":1,"imageOffset":4096}]}],
         "usedImages":[{"name":"wined3d.dll.so","path":"\/Users\/ivanov\/x"},{"name":"libdxmt.dylib"}]}
        """#
        let summary = try #require(DiagnosticsCollector.crashSummary(header + "\n" + body))
        #expect(summary.contains("EXC_BAD_ACCESS") && summary.contains("wined3d.dll.so wined3d_device_create") && summary.contains("libdxmt.dylib +4096"))
        for secret in ["SECRET-KEY", "DEVICE-ID", "BOOT-ID", "ivanov", "501"] { #expect(!summary.contains(secret), "\(secret)") }
    }
}

@Suite(.serialized) struct SignatureTests {
    @Test func onlyTheKeysSignatureOfTheseBytes() {
        let key = Curve25519.Signing.PrivateKey(), other = Curve25519.Signing.PrivateKey()
        let saved = (Signature.publicKey, Signature.required)
        Signature.publicKey = key.publicKey
        defer { (Signature.publicKey, Signature.required) = saved }
        let data = Data(#"{"version":1,"rules":[]}"#.utf8)
        let good = try! key.signature(for: data).base64EncodedString()
        #expect(Signature.accepts(data, signature: good))
        #expect(!Signature.accepts(data, signature: try! other.signature(for: data).base64EncodedString()))
        #expect(!Signature.accepts(Data(#"{"version":1,"rules":[1]}"#.utf8), signature: good))
        Signature.required = true
        #expect(!Signature.accepts(data, signature: nil))        // release builds: nothing unsigned
        Signature.required = false
        #expect(Signature.accepts(data, signature: nil))         // debug builds: the local services don't sign
        #expect(!Signature.accepts(data, signature: "garbage"))  // but a wrong one is never taken
    }

    @Test func onlyGraphicsAndWineVariables() {
        for key in ["DXMT_CONFIG", "D3DM_ENABLE_METALFX", "MTL_HUD_ENABLED", "SOMMELIER_HIDE_WINE", "WINEESYNC"] { #expect(FixAction.allowsEnvironment(key), "\(key)") }
        for key in ["DYLD_INSERT_LIBRARIES", "WINESERVER", "WINELOADER", "PATH", "HOME", "DXMT_", "WINEPREFIX", "WINEDLLOVERRIDES"] { #expect(!FixAction.allowsEnvironment(key), "\(key)") }
    }
}
