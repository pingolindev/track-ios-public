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
import MetricKit
import UIKit

/// The day's energy numbers, from MetricKit.
///
/// WHY THIS EXISTS
///   The battery cost of the polling model, the keep-alive and the check-in
///   cadence has to be measured, not argued from code. MetricKit measures
///   exactly these numbers on every device, once a day, with no tester doing
///   anything:
///   - how long each ACCURACY was requested (`MXLocationActivityMetric`) — Best
///     time per day is the poll's GPS duty, ThreeKilometers the keep-alive;
///   - foreground, background and background-location time
///     (`MXAppRunTimeMetric`) — residency;
///   - CPU time (`MXCPUMetric`) and bytes moved (`MXNetworkTransferMetric`) —
///     what the timers and polls cost while resident.
///
/// WHERE IT GOES
///   - DEBUG: every payload's full JSON is written to `Documents/metrickit/`,
///     readable from a developer-signed install.
///   - DEBUG and RELEASE_DEV (TestFlight): a summary of NUMBERS ONLY — app
///     version, build, OS version and the metrics above; no coordinates, no
///     user or device id — is POSTed to the server's
///     `/api/v1/diagnostics/energy`. The endpoint exists only where the server
///     enables it (dev); anywhere else it answers 404 and the report is
///     dropped.
///   - Release (App Store): nothing. Not even the subscription.
final class EnergyMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = EnergyMetrics()

    /// Whether this build reports at all. A compile-time decision, so an App
    /// Store build cannot be talked into it.
    static let isEnabled: Bool = {
        #if DEBUG || RELEASE_DEV
        return true
        #else
        return false
        #endif
    }()

    static let endpointPath = "/api/v1/diagnostics/energy"
    /// The server rejects more; the mapping below produces 16.
    static let maxMetrics = 32
    /// Reports that could not be sent (offline, token expired) wait here for
    /// the next launch or payload. A week of them at most.
    static let maxPending = 7

    private var started = false

    private override init() {
        super.init()
    }

    /// Subscribe. Call once, early in launch; repeat calls are no-ops.
    func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        MXMetricManager.shared.add(self)
        Task { @MainActor in await self.flushPending() }
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard Self.isEnabled else { return }
        for payload in payloads {
            #if DEBUG
            Self.writeDebugPayload(payload)
            #endif
            let report = Self.report(
                from: Self.sample(from: payload),
                appVersion: AppConfiguration.shared.appVersion,
                fallbackBuild: AppConfiguration.shared.buildNumber,
                fallbackOSVersion: UIDevice.current.systemVersion
            )
            Self.enqueue(report)
        }
        Task { @MainActor in await self.flushPending() }
    }

    // MARK: - Mapping (pure, tested)

    /// The numbers one payload carries, as plain values: `MXMetricPayload` has
    /// no public initializer, so the mapping below is tested against this.
    struct Sample: Equatable {
        var periodBegin: Date
        var periodEnd: Date
        var appBuild: String?
        var osVersion: String?

        var locationBestForNavigationSeconds: Double?
        var locationBestSeconds: Double?
        var locationTenMetersSeconds: Double?
        var locationHundredMetersSeconds: Double?
        var locationKilometerSeconds: Double?
        var locationThreeKilometersSeconds: Double?

        var foregroundSeconds: Double?
        var backgroundSeconds: Double?
        var backgroundLocationSeconds: Double?
        var backgroundAudioSeconds: Double?

        var cpuSeconds: Double?

        var wifiUploadBytes: Double?
        var wifiDownloadBytes: Double?
        var cellularUploadBytes: Double?
        var cellularDownloadBytes: Double?
    }

    /// The body `POST /api/v1/diagnostics/energy` takes.
    struct Report: Codable, Equatable {
        let platform: String
        let appVersion: String
        let appBuild: String
        let osVersion: String
        let periodHours: Double
        let metrics: [String: Double]

        enum CodingKeys: String, CodingKey {
            case platform
            case appVersion = "app_version"
            case appBuild = "app_build"
            case osVersion = "os_version"
            case periodHours = "period_hours"
            case metrics
        }
    }

    /// Snake_case metric names to values, dropping anything absent, negative or
    /// not finite, rounded to milli-units so a report is a few hundred bytes.
    static func metrics(from sample: Sample) -> [String: Double] {
        let pairs: [(String, Double?)] = [
            ("location_best_navigation_s", sample.locationBestForNavigationSeconds),
            ("location_best_s", sample.locationBestSeconds),
            ("location_10m_s", sample.locationTenMetersSeconds),
            ("location_100m_s", sample.locationHundredMetersSeconds),
            ("location_1km_s", sample.locationKilometerSeconds),
            ("location_3km_s", sample.locationThreeKilometersSeconds),
            ("foreground_s", sample.foregroundSeconds),
            ("background_s", sample.backgroundSeconds),
            ("background_location_s", sample.backgroundLocationSeconds),
            ("background_audio_s", sample.backgroundAudioSeconds),
            ("cpu_s", sample.cpuSeconds),
            ("wifi_up_bytes", sample.wifiUploadBytes),
            ("wifi_down_bytes", sample.wifiDownloadBytes),
            ("cell_up_bytes", sample.cellularUploadBytes),
            ("cell_down_bytes", sample.cellularDownloadBytes),
        ]
        var out: [String: Double] = [:]
        for (key, value) in pairs.prefix(maxMetrics) {
            guard let value, value.isFinite, value >= 0 else { continue }
            out[key] = (value * 1000).rounded() / 1000
        }
        return out
    }

    static func report(
        from sample: Sample,
        appVersion: String,
        fallbackBuild: String,
        fallbackOSVersion: String
    ) -> Report {
        let hours = max(0, sample.periodEnd.timeIntervalSince(sample.periodBegin)) / 3600
        return Report(
            platform: "ios",
            appVersion: appVersion,
            // The build that PRODUCED the numbers, which is not always the one
            // running now: MetricKit delivers yesterday's payload after an update.
            appBuild: sample.appBuild ?? fallbackBuild,
            osVersion: sample.osVersion ?? fallbackOSVersion,
            periodHours: (hours * 100).rounded() / 100,
            metrics: metrics(from: sample)
        )
    }

    // MARK: - MetricKit adapter

    static func sample(from payload: MXMetricPayload) -> Sample {
        func seconds(_ m: Measurement<UnitDuration>?) -> Double? {
            m?.converted(to: .seconds).value
        }
        func bytes(_ m: Measurement<UnitInformationStorage>?) -> Double? {
            m?.converted(to: .bytes).value
        }
        let location = payload.locationActivityMetrics
        let runTime = payload.applicationTimeMetrics
        let network = payload.networkTransferMetrics
        return Sample(
            periodBegin: payload.timeStampBegin,
            periodEnd: payload.timeStampEnd,
            appBuild: payload.metaData?.applicationBuildVersion,
            osVersion: payload.metaData?.osVersion,
            locationBestForNavigationSeconds: seconds(location?.cumulativeBestAccuracyForNavigationTime),
            locationBestSeconds: seconds(location?.cumulativeBestAccuracyTime),
            locationTenMetersSeconds: seconds(location?.cumulativeNearestTenMetersAccuracyTime),
            locationHundredMetersSeconds: seconds(location?.cumulativeHundredMetersAccuracyTime),
            locationKilometerSeconds: seconds(location?.cumulativeKilometerAccuracyTime),
            locationThreeKilometersSeconds: seconds(location?.cumulativeThreeKilometersAccuracyTime),
            foregroundSeconds: seconds(runTime?.cumulativeForegroundTime),
            backgroundSeconds: seconds(runTime?.cumulativeBackgroundTime),
            backgroundLocationSeconds: seconds(runTime?.cumulativeBackgroundLocationTime),
            backgroundAudioSeconds: seconds(runTime?.cumulativeBackgroundAudioTime),
            cpuSeconds: seconds(payload.cpuMetrics?.cumulativeCPUTime),
            wifiUploadBytes: bytes(network?.cumulativeWifiUpload),
            wifiDownloadBytes: bytes(network?.cumulativeWifiDownload),
            cellularUploadBytes: bytes(network?.cumulativeCellularUpload),
            cellularDownloadBytes: bytes(network?.cumulativeCellularDownload)
        )
    }

    #if DEBUG
    private static func writeDebugPayload(_ payload: MXMetricPayload) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("metrickit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
            .replacingOccurrences(of: ":", with: "-")
        try? payload.jsonRepresentation().write(to: dir.appendingPathComponent("\(stamp).json"))
    }
    #endif

    // MARK: - Pending reports

    private static var pendingURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("energy-reports-pending.json")
    }

    private static func loadPending() -> [Report] {
        guard let url = pendingURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Report].self, from: data)) ?? []
    }

    private static func savePending(_ reports: [Report]) {
        guard let url = pendingURL else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if reports.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(reports) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func enqueue(_ report: Report) {
        savePending(Array((loadPending() + [report]).suffix(maxPending)))
    }

    // MARK: - Upload

    /// What to do with a report after one attempt.
    enum UploadVerdict: Equatable {
        /// Delivered, or refused for good (404 = endpoint off; 4xx = a body
        /// the server will never take). Either way, forget it.
        case done
        /// Try again later: offline, a server error, or no valid token.
        case retry
    }

    static func verdict(forStatus status: Int?) -> UploadVerdict {
        guard let status else { return .retry }
        switch status {
        case 200...299, 404: return .done
        case 401, 403, 408, 429: return .retry
        case 400...499: return .done
        default: return .retry
        }
    }

    /// The upload carries the access token, so it goes through a session that
    /// keeps nothing on disk — the API session's configuration: no response
    /// cache (the shared one stored each request WITH its Authorization
    /// header), no cookies.
    private static let uploadSession = TrustBlocklist.session(configuration: APIService.makeSessionConfiguration())

    /// Send what is waiting. Uses the stored access token only while it is
    /// valid for another minute: this never refreshes a token itself — a
    /// diagnostics upload is not worth rotating the single-use refresh token
    /// for — so an expired token just leaves the reports for next time.
    @MainActor
    private func flushPending() async {
        var pending = Self.loadPending()
        guard !pending.isEmpty,
              AuthManager.shared.accessTokenValid(forAtLeast: 60),
              let token = KeychainService.shared.getString(for: .accessToken),
              let url = URL(string: AppConfiguration.shared.apiBaseURL + Self.endpointPath)
        else { return }
        var kept: [Report] = []
        for report in pending {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(AppConfiguration.shared.userAgent, forHTTPHeaderField: "User-Agent")
            request.httpBody = try? JSONEncoder().encode(report)
            let status = try? await (Self.uploadSession.data(for: request).1 as? HTTPURLResponse)?.statusCode
            if Self.verdict(forStatus: status) == .retry { kept.append(report) }
        }
        pending = kept
        Self.savePending(pending)
    }
}
