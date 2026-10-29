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

/// The records read: every circle's refresh records above what this device
/// already holds, and the heads of its active members, in one call, paged,
/// the same map continuing it.
///
/// The server is only asked, never trusted. A reply that doesn't hold together
/// is no answer (nil): the caller keeps what it holds and asks again later,
/// never with part of a chain.
/// - every record is above its circle's `since` and above the one before it,
///   in version order, each once;
/// - every record and signature is hex at the lengths the format allows; heads
///   are 69 bytes with 64-byte signatures;
/// - heads come only with a circle's last page (`complete`);
/// - a page that says `more` but moves nothing on is a loop, and ends it.
/// What the records SAY is the SDK's to check.
enum RefreshRecordsReader {
    /// One circle's records above its `since`, oldest first, and the heads of
    /// its active members (this account's own included).
    struct Circle: Equatable {
        let circleId: String
        var records: [ServedRefreshRecord]
        var heads: [ServedCircleHead]
    }

    /// The most pages one read follows (100 records each): far above any real
    /// circle.
    static let maxPages = 50
    /// The server's highest version (its `since` bound).
    static let maxVersion = 1_000_000
    /// A record's WIRE is at least a body naming nobody and a key tag, and at
    /// most a transition naming 200 members.
    static let minWireBytes = 103 + 32
    static let maxWireBytes = 103 + 66 * 200 + 64
    static let signatureBytes = 64
    static let headBytes = 69

    /// Read every circle's records above `since` (a circle it doesn't name:
    /// from 0), following the pages to the end. `page` is the API call.
    static func read(since: [String: Int32],
                     page: ([String: Int32]) async throws -> RefreshRecordsPage) async -> [Circle]? {
        var map = Dictionary(since.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var got: [String: Circle] = [:]
        var order: [String] = []
        var complete = Set<String>()
        for _ in 0..<maxPages {
            guard let reply = try? await page(map) else { return nil }
            var moved = false
            for served in reply.circles {
                let circleId = served.circleId.lowercased()
                guard isUUID(circleId) else { return nil }
                if got[circleId] == nil { order.append(circleId) }
                var entry = got[circleId] ?? Circle(circleId: circleId, records: [], heads: [])
                var floor = entry.records.last.map(\.version) ?? Int(map[circleId] ?? 0)
                for record in served.records {
                    guard record.version > floor, record.version <= maxVersion,
                          isHex(record.record, bytes: minWireBytes...maxWireBytes),
                          isHex(record.signature, bytes: signatureBytes...signatureBytes) else { return nil }
                    entry.records.append(record)
                    floor = record.version
                    moved = true
                }
                if served.complete {
                    // Every page lists every circle; a complete one carries its
                    // heads each time, and the newest page's are the ones that
                    // stand.
                    var heads: [ServedCircleHead] = []
                    for head in served.heads {
                        let userId = head.userId.lowercased()
                        guard isUUID(userId), isHex(head.head, bytes: headBytes...headBytes),
                              isHex(head.signature, bytes: signatureBytes...signatureBytes) else { return nil }
                        heads.append(ServedCircleHead(userId: userId, head: head.head, signature: head.signature))
                    }
                    entry.heads = heads
                    complete.insert(circleId)
                } else if !served.heads.isEmpty {
                    return nil
                } else {
                    complete.remove(circleId)
                }
                got[circleId] = entry
            }
            guard reply.more else {
                // The last page: every circle it lists is complete.
                guard got.keys.allSatisfy(complete.contains) else { return nil }
                return order.compactMap { got[$0] }
            }
            guard moved else { return nil }
            for (circleId, entry) in got {
                if let last = entry.records.last { map[circleId] = Int32(last.version) }
            }
        }
        return nil
    }

    private static func isUUID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil
    }

    private static func isHex(_ value: String, bytes: ClosedRange<Int>) -> Bool {
        value.count % 2 == 0 && bytes.contains(value.count / 2)
            && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}
