// Copyright 2026 the Sommelier project.
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A value from Valve's text KeyValues files (`libraryfolders.vdf`, `appmanifest_*.acf`): either a leaf string or
/// a block of key/value pairs. Blocks keep their order and any repeated keys, because Steam's files can have both.
public indirect enum VDFValue: Sendable, Equatable {
    /// One key/value pair of a block.
    public typealias Entry = (key: String, value: VDFValue)

    case string(String), object([Entry])

    // Tuples aren't Equatable, so blocks are compared pair by pair.
    public static func == (a: VDFValue, b: VDFValue) -> Bool {
        switch (a, b) {
        case (.string(let left), .string(let right)):
            return left == right
        case (.object(let left), .object(let right)):
            guard left.count == right.count else { return false }
            for (l, r) in zip(left, right) where l.key != r.key || l.value != r.value { return false }
            return true
        case (.string, .object), (.object, .string):
            return false
        }
    }

    /// The text of a leaf; nil for a block.
    public var string: String? {
        guard case .string(let text) = self else { return nil }
        return text
    }

    /// The pairs of a block; nil for a leaf.
    public var entries: [Entry]? {
        guard case .object(let pairs) = self else { return nil }
        return pairs
    }

    /// The first child named `key`. Steam ignores case in key names, so this does too.
    public subscript(_ key: String) -> VDFValue? {
        guard let pairs = entries else { return nil }
        for pair in pairs where pair.key.compare(key, options: .caseInsensitive) == .orderedSame { return pair.value }
        return nil
    }

    /// Walks down through nested blocks, one key per level.
    public func value(at keys: String...) -> VDFValue? {
        keys.reduce(Optional(self)) { node, key in node?[key] }
    }
}

/// Why a KeyValues document couldn't be read. Offsets count Unicode scalars from the start of the text.
public enum VDFError: Equatable, Error {
    /// The text stopped inside a block or right after a key; a brace stood where none can be; a quote never closed.
    case unexpectedEnd, unexpectedToken(String, offset: Int), unterminatedString(offset: Int)
}

/// Reads the text KeyValues format: quoted or bare strings, `{ }` blocks, `//` line comments and backslash escapes.
public enum VDFParser {
    /// Parses a whole document; its top-level pairs become one block.
    public static func parse(_ document: String) throws -> VDFValue {
        var reader = Reader(document)
        return .object(try readBlock(&reader, closedByBrace: false))
    }

    /// Reads pairs until the closing brace (inside a block) or the end of the text (at the top level).
    private static func readBlock(_ reader: inout Reader, closedByBrace: Bool) throws -> [VDFValue.Entry] {
        var pairs: [VDFValue.Entry] = []
        while let token = try reader.token() {
            let key: String
            switch token {
            case .text(let name): key = name
            case .closeBrace:
                guard closedByBrace else { throw VDFError.unexpectedToken("}", offset: reader.offset) }
                return pairs
            case .openBrace:
                throw VDFError.unexpectedToken("{", offset: reader.offset)
            }
            switch try reader.token() {
            case nil: throw VDFError.unexpectedEnd
            case .text(let leaf)?: pairs.append((key: key, value: .string(leaf)))
            case .openBrace?: pairs.append((key: key, value: .object(try readBlock(&reader, closedByBrace: true))))
            case .closeBrace?: throw VDFError.unexpectedToken("}", offset: reader.offset)
            }
        }
        if closedByBrace { throw VDFError.unexpectedEnd }
        return pairs
    }

    private enum Token { case text(String), openBrace, closeBrace }

    /// Splits the text into tokens, skipping blanks, a byte-order mark and comments.
    private struct Reader {
        private let scalars: [Unicode.Scalar]
        private(set) var offset = 0

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        private var current: Unicode.Scalar? { offset < scalars.count ? scalars[offset] : nil }

        private func peek(_ ahead: Int) -> Unicode.Scalar? {
            offset + ahead < scalars.count ? scalars[offset + ahead] : nil
        }

        mutating func token() throws -> Token? {
            skipBlanks()
            guard let first = current else { return nil }
            if first == "{" { offset += 1; return .openBrace }
            if first == "}" { offset += 1; return .closeBrace }
            if first == "\"" { return .text(try quotedText()) }
            return .text(bareText())
        }

        private mutating func skipBlanks() {
            while let scalar = current {
                if scalar.properties.isWhitespace || scalar == "\u{FEFF}" {
                    offset += 1
                } else if scalar == "/" && peek(1) == "/" {
                    while let next = current, next != "\n" { offset += 1 }
                } else {
                    return
                }
            }
        }

        /// A string in double quotes. `\n`, `\t`, `\\` and `\"` are unescaped; any other backslash stays as written.
        private mutating func quotedText() throws -> String {
            let opening = offset
            offset += 1
            var text = String.UnicodeScalarView()
            while let scalar = current {
                offset += 1
                if scalar == "\"" { return String(text) }
                guard scalar == "\\", let escaped = current else { text.append(scalar); continue }
                offset += 1
                switch escaped {
                case "n": text.append("\n")
                case "t": text.append("\t")
                case "\\", "\"": text.append(escaped)
                default: text.append(contentsOf: ["\\", escaped])
                }
            }
            throw VDFError.unterminatedString(offset: opening)
        }

        /// An unquoted word: runs until a blank, a brace or a quote.
        private mutating func bareText() -> String {
            var text = String.UnicodeScalarView()
            while let scalar = current, !scalar.properties.isWhitespace, !"{}\"".unicodeScalars.contains(scalar) {
                text.append(scalar)
                offset += 1
            }
            return String(text)
        }
    }
}
