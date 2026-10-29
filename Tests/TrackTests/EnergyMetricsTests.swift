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

import XCTest
@testable import Track

/// The MetricKit summary a dev build reports to `/api/v1/diagnostics/energy`.
///
/// WHY THIS IS WORTH TESTING
///   The report is the only field measurement of the app's energy cost that
///   exists, and what it may carry is a privacy boundary: numbers, the app and
///   OS version, nothing that identifies a person or a place. `MXMetricPayload`
///   has no public initializer, so the mapping is tested through `Sample`.
final class EnergyMetricsTests: XCTestCase {

    private let begin = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ edit: (inout EnergyMetrics.Sample) -> Void = { _ in }) -> EnergyMetrics.Sample {
        var s = EnergyMetrics.Sample(periodBegin: begin, periodEnd: begin.addingTimeInterval(86_400))
        s.appBuild = "77"
        s.osVersion = "iPhone OS 26.4 (23E244)"
        s.locationBestSeconds = 612.25
        s.locationThreeKilometersSeconds = 86_000
        s.backgroundLocationSeconds = 85_000
        s.cpuSeconds = 41.5
        s.cellularDownloadBytes = 1_048_576
        edit(&s)
        return s
    }

    func testTheMetricNamesAreTheOnesTheEndpointExpects() {
        let metrics = EnergyMetrics.metrics(from: sample())
        XCTAssertEqual(metrics["location_best_s"], 612.25)
        XCTAssertEqual(metrics["location_3km_s"], 86_000, "the keep-alive's residency")
        XCTAssertEqual(metrics["background_location_s"], 85_000)
        XCTAssertEqual(metrics["cpu_s"], 41.5)
        XCTAssertEqual(metrics["cell_down_bytes"], 1_048_576)
        XCTAssertNil(metrics["location_10m_s"], "an absent measurement is omitted, not reported as zero")
        for key in metrics.keys {
            XCTAssertNotNil(key.range(of: "^[a-z0-9_]{1,48}$", options: .regularExpression), key)
        }
        XCTAssertLessThanOrEqual(metrics.count, EnergyMetrics.maxMetrics)
    }

    func testNegativeAndNonFiniteValuesAreDropped() {
        let metrics = EnergyMetrics.metrics(from: sample {
            $0.cpuSeconds = -1
            $0.locationBestSeconds = .nan
            $0.foregroundSeconds = .infinity
        })
        XCTAssertNil(metrics["cpu_s"])
        XCTAssertNil(metrics["location_best_s"])
        XCTAssertNil(metrics["foreground_s"])
    }

    func testTheReportCarriesNumbersAndVersionsOnly() throws {
        let report = EnergyMetrics.report(
            from: sample(), appVersion: "1.0.0", fallbackBuild: "80", fallbackOSVersion: "26.5")
        XCTAssertEqual(report.platform, "ios")
        XCTAssertEqual(report.appBuild, "77", "the build that produced the numbers, not the one running now")
        XCTAssertEqual(report.periodHours, 24)

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        XCTAssertEqual(Set(json.keys),
                       ["platform", "app_version", "app_build", "os_version", "period_hours", "metrics"],
                       "nothing else — no user, device, circle or position — may ride along")
        let metrics = try XCTUnwrap(json["metrics"] as? [String: Double])
        XCTAssertEqual(metrics["location_best_s"], 612.25, "metric keys are sent verbatim, not re-cased")
    }

    func testMissingMetadataFallsBackToThisBuild() {
        let report = EnergyMetrics.report(
            from: sample { $0.appBuild = nil; $0.osVersion = nil },
            appVersion: "1.0.0", fallbackBuild: "80", fallbackOSVersion: "26.5")
        XCTAssertEqual(report.appBuild, "80")
        XCTAssertEqual(report.osVersion, "26.5")
    }

    func testOnlyATransientFailureIsRetried() {
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: 204), .done)
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: 404), .done,
                       "404 = the endpoint is switched off on this server; never retry into it")
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: 400), .done, "a body the server will never take")
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: 401), .retry)
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: 503), .retry)
        XCTAssertEqual(EnergyMetrics.verdict(forStatus: nil), .retry, "offline")
    }

    func testAppStoreBuildsNeverReport() {
        #if DEBUG || RELEASE_DEV
        XCTAssertTrue(EnergyMetrics.isEnabled)
        #else
        XCTAssertFalse(EnergyMetrics.isEnabled)
        #endif
    }
}
