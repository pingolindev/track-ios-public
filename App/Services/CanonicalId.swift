// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Track.
//
// Pingolin Track is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Track is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Track. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import os

/// An account's or a circle's id in its one form: the 36 characters of a
/// hyphenated UUID, lower-cased. The app, the extension and the SDK must
/// agree on who is who: an id spelt another way would miss this device's
/// pins for that person, or take this account itself for a stranger.
enum CanonicalId {
    static let log = Logger(subsystem: "com.pingolin.track", category: "ids")

    /// Every spelling of a UUID the SDK parses (uuid 1.24: 36 hyphenated
    /// characters in any case, 32 bare hex digits, braced, "urn:uuid:"), in
    /// the one form; nil for anything that isn't a UUID.
    static func of(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let bytes = Array(raw.utf8)
        let hyphenated: String
        switch bytes.count {
        case 32:
            guard bytes.allSatisfy(isHex) else { return nil }
            let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(decoding: bytes[$0], as: UTF8.self) }
            hyphenated = groups.joined(separator: "-")
        case 36:
            hyphenated = raw
        case 38 where bytes.first == UInt8(ascii: "{") && bytes.last == UInt8(ascii: "}"):
            hyphenated = String(decoding: bytes[1..<37], as: UTF8.self)
        case 45 where raw.hasPrefix("urn:uuid:"):
            hyphenated = String(decoding: bytes[9...], as: UTF8.self)
        default:
            return nil
        }
        return strict(hyphenated)
    }

    /// Only the 36 hyphenated characters, in any case, in the one form: the
    /// invitation's lookup, where any other spelling is no answer.
    static func strict(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count == 36, let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    /// What two ids this device already holds are compared by: the one form,
    /// else the id lower-cased. A served id that isn't a UUID never gets this
    /// far (`ServedId`); one that did would still equal no account.
    static func key(_ raw: String) -> String {
        of(raw) ?? raw.lowercased()
    }

    /// Whether two ids are UUIDs, and the same one, whatever their spellings.
    /// False when either is no UUID: such an id is nobody's. Every compare
    /// that lets someone in or says "this is me" asks this.
    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a = of(a) else { return false }
        return a == of(b)
    }

    /// Whether two ids file under one `key`, so equal non-UUIDs too; false
    /// when either is nil. Only for a store's own keys and for compares that
    /// keep someone OUT (a removal's subject, an eject): there a non-UUID
    /// still matches, never "false for anything odd".
    static func sameKey(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return key(a) == key(b)
    }

    /// A served id that is no UUID at all: the entry naming it is refused
    /// where it comes in, never passed on.
    struct NotAnId: Error, Equatable {}

    /// The slot the account's PERSONAL key is held under (the SDK's
    /// `PERSONAL_KEY_ID`), which is never a circle's: a circle listed under
    /// it would have the personal key wrapped to its members.
    static let personalSlot = "00000000-0000-0000-0000-000000000000"

    /// Whether `raw`, in any spelling, is the personal key's slot.
    static func isPersonalSlot(_ raw: String?) -> Bool {
        of(raw) == personalSlot
    }

    /// A served circle id in its one form; nil for one no circle may have:
    /// no UUID at all, or the personal key's slot in any spelling.
    static func circle(_ raw: String?) -> String? {
        guard let id = of(raw), id != personalSlot else { return nil }
        return id
    }

    /// A served circle id that is no circle's (`circle`): the entry carrying
    /// it is refused where it comes in.
    struct NotACircle: Error, Equatable {}

    private static func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}

/// An account id as the server serves it, taken in its one form as it is
/// decoded. One that is no UUID at all fails the decode (`CanonicalId.NotAnId`):
/// a list drops that entry (`ServedEntries`, `Paginated`), anything else is
/// refused whole.
@propertyWrapper
struct ServedId: Codable, Equatable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = CanonicalId.of(raw) else { throw CanonicalId.NotAnId() }
        wrappedValue = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// `ServedId` for an id the server may leave out. Absent or null is nil; an
/// id that is no UUID is refused, never read as absent (absent can mean "this
/// account's own", e.g. a wrap's sender).
@propertyWrapper
struct ServedOptionalId: Codable, Equatable {
    var wrappedValue: String?

    init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        guard let id = CanonicalId.of(try container.decode(String.self)) else { throw CanonicalId.NotAnId() }
        wrappedValue = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// A circle id as the server serves it, taken in its one form as it is
/// decoded. One that is no circle's (no UUID, or the personal key's slot in
/// any spelling: `CanonicalId.circle`) fails the decode
/// (`CanonicalId.NotACircle`): a list drops that entry (`ServedEntries`,
/// `Paginated`), anything else is refused whole.
@propertyWrapper
struct ServedCircleId: Codable, Equatable {
    var wrappedValue: String

    init(wrappedValue: String) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let id = CanonicalId.circle(raw) else { throw CanonicalId.NotACircle() }
        wrappedValue = id
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A `ServedOptionalId` whose key is missing is nil, as a plain optional's is.
    func decode(_ type: ServedOptionalId.Type, forKey key: Key) throws -> ServedOptionalId {
        try decodeIfPresent(type, forKey: key) ?? ServedOptionalId(wrappedValue: nil)
    }
}

/// A served list whose entries name accounts or circles: an entry naming an
/// account by no UUID at all, or a circle by an id no circle may have, is
/// dropped and counted in the log, and the rest are read. Any other failure
/// fails the list.
struct ServedEntries<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        var refused = 0
        var notCircles = 0
        while !container.isAtEnd {
            switch try container.decode(Attempt<Element>.self) {
            case .read(let item): items.append(item)
            case .refused: refused += 1
            case .notACircle: notCircles += 1
            }
        }
        if refused > 0 {
            CanonicalId.log.error("refused \(refused, privacy: .public) served entries naming an account by no id")
        }
        if notCircles > 0 {
            CanonicalId.log.error("refused \(notCircles, privacy: .public) served entries naming a circle by an id no circle has")
        }
        self.items = items
    }

    /// One entry, read or refused, so the list moves past it either way.
    private enum Attempt<T: Decodable>: Decodable {
        case read(T)
        case refused
        case notACircle

        init(from decoder: Decoder) throws {
            do {
                self = .read(try T(from: decoder))
            } catch is CanonicalId.NotAnId {
                self = .refused
            } catch is CanonicalId.NotACircle {
                self = .notACircle
            }
        }
    }
}

extension Array {
    /// What a list keeps of a circle this account is in no more: the
    /// entries of every other circle, by the ids' one form.
    func withoutCircle(_ circleId: String, of circle: (Element) -> String) -> [Element] {
        filter { !CanonicalId.sameKey(circle($0), circleId) }
    }
}
