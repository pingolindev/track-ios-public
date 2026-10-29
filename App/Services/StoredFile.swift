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

/// What a store finds in its file. A file that is there but can't be read now
/// (protected until the first unlock after a restart) or doesn't decode
/// (damaged, or a newer build's) is never taken for "nothing stored": the next
/// write would save an empty store over it and drop what it held. The store
/// writes nothing then, and reads it again at its next use.
enum StoredFile<Value: Decodable> {
    /// No file: nothing stored.
    case missing
    case loaded(Value)
    /// There, and not read.
    case unreadable

    static func read(_ url: URL?) -> StoredFile<Value> {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Value.self, from: data) else { return .unreadable }
        return .loaded(value)
    }
}
