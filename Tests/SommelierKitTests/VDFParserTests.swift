// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import SommelierKit

@Suite struct VDFParserTests {
    private func parsedFixture(_ name: String) throws -> VDFValue {
        let file = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try VDFParser.parse(String(contentsOf: file, encoding: .utf8))
    }

    @Test func steamLibraryFoldersFile() throws {
        let first = try #require(try parsedFixture("libraryfolders.vdf").value(at: "libraryfolders", "0"))
        #expect(first["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(first["apps"]?.entries?.map { $0.key } == ["228980", "268910"])
        #expect(first.value(at: "apps", "268910")?.string == "4044947883")
    }

    @Test func steamAppManifest() throws {
        let app = try #require(try parsedFixture("appmanifest_268910.acf")["AppState"])
        #expect(app["appid"]?.string == "268910")
        #expect(app["name"]?.string == "Cuphead")
        #expect(app["StateFlags"]?.string == "4")
        #expect(app.value(at: "InstalledDepots", "268911", "size")?.string == "4044947883")
        #expect(app["InstalledDepots"]?.string == nil)        // a block has no text
    }

    @Test func keysMatchWhateverTheirCase() throws {
        let doc = try VDFParser.parse(#""Outer" { "Inner" "v" }"#)
        #expect(doc.value(at: "OUTER", "inner")?.string == "v")
        #expect(doc.value(at: "outer", "missing") == nil)
    }

    @Test func escapesCommentsAndUnquotedWords() throws {
        let doc = try VDFParser.parse("""
        // a comment line
        "root" {
            "path" "C:\\\\Games\\\\x"   // comment after a value
            "quote" "a \\"quoted\\" word\\n"
            "tab" "a\\tb"
            "other" "\\q"
            bare value
        }
        """)
        let root = try #require(doc["root"])
        #expect(root["path"]?.string == #"C:\Games\x"#)
        #expect(root["quote"]?.string == "a \"quoted\" word\n")
        #expect(root["tab"]?.string == "a\tb")
        #expect(root["other"]?.string == #"\q"#)            // unknown escapes stay as written
        #expect(root["bare"]?.string == "value")
    }

    @Test func byteOrderMarkIsSkipped() throws {
        #expect(try VDFParser.parse("\u{FEFF}\"k\" \"v\"")["k"]?.string == "v")
    }

    @Test func repeatedKeysAreAllKeptInOrder() throws {
        let block = try #require(try VDFParser.parse(#""r" { "k" "1" "k" "2" }"#)["r"])
        #expect(block.entries?.map { $0.value.string } == ["1", "2"])
        #expect(block["k"]?.string == "1")                  // lookups take the first
    }

    @Test func brokenDocumentsThrow() {
        #expect(throws: VDFError.unexpectedEnd) { try VDFParser.parse(#""r" { "k" "v""#) }
        #expect(throws: VDFError.unexpectedEnd) { try VDFParser.parse(#""key-without-value""#) }
        #expect(throws: VDFError.unexpectedToken("}", offset: 5)) { try VDFParser.parse(#""k" }"#) }
        #expect(throws: VDFError.unexpectedToken("{", offset: 1)) { try VDFParser.parse("{ }") }
        #expect(throws: VDFError.unterminatedString(offset: 10)) { try VDFParser.parse(#""r" { "k" "unterminated }"#) }
    }

    @Test func nothingParsesToAnEmptyBlock() throws {
        for empty in ["", "  // only a comment\n", "\n\t "] {
            #expect(try VDFParser.parse(empty) == VDFValue.object([]))
        }
    }

    @Test func equalityLooksAtOrderAndContents() throws {
        let one = try VDFParser.parse(#""a" "1" "b" "2""#)
        #expect(one == (try VDFParser.parse(#""a" "1" "b" "2""#)))
        #expect(one != (try VDFParser.parse(#""b" "2" "a" "1""#)))
        #expect(VDFValue.string("x") != .object([]))
    }
}
