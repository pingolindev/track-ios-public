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

import SwiftUI

/// Auth container. One screen: the app signs in, it does not sign up —
/// registration happens in the account portal (LoginView links out to it).
/// The type exists because TrackApp's unauthenticated branch names it, and a
/// second auth screen would land here.
struct AuthView: View {
    var body: some View {
        LoginView()
    }
}

#Preview {
    AuthView()
}
