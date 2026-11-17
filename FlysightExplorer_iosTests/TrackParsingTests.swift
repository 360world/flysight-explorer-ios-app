//
//  TrackParsingTests.swift — unit tests for CSV parsing and jump detection.
//

import Foundation
import Testing
@testable import FlysightExplorer_ios

@MainActor
struct TrackParsingTests {

    // MARK: - Bundled samples

    @Test(arguments: SampleTrack.allCases)
    func bundledSampleLoadsAndDetectsJump(_ sample: SampleTrack) throws {
        let track = try #require(sample.load("en"))
        #expect(track.count > 1000)
        let exit = try #require(track.exitIdx)
        let deploy = try #require(track.deployIdx)
        let land = try #require(track.landIdx)
        #expect(exit < deploy)
        #expect(deploy <= land)
        // Exit altitude in the sample subtitles is ~4100 m MSL.
        #expect(track.samples[exit].altM > 3500)
        #expect(track.cumDistM.count == track.count)
    }

    // MARK: - Formats

    /// Real FlySight 2 TRACK.CSV rows: ISO time first, CR line endings.
    @Test func parsesIsoFormatWithCarriageReturns() throws {
        var rows: [String] = []
        for i in 0..<10 {
            let sec = String(format: "%02d", i)
            rows.append("2025-06-01T10:00:\(sec).00Z,47.0,19.0,\(4000 - i),1.0,2.0,3.0,1.2,2.0,0.3,3,20")
        }
        let track = try #require(Track.parse(rows.joined(separator: "\r"), name: "iso"))
        #expect(track.count == 10)
        #expect(track.samples[1].t == 1)
        #expect(track.samples[0].numSV == 20)
        #expect(track.recordedAt == Track.isoDate("2025-06-01T10:00:00.000Z"))
    }

    @Test func parsesGnssPrefixedRows() throws {
        let rows = (0..<8).map { i in
            "$GNSS,2025-06-01T10:00:0\(i).5Z,47.0,19.0,1000,0,0,0,1,1,1,3,12"
        }
        let track = try #require(Track.parse(rows.joined(separator: "\n"), name: "gnss"))
        #expect(track.count == 8)
        #expect(track.samples.last?.t == 7)
    }

    @Test func rejectsTooFewSamples() {
        let rows = (0..<5).map { "\($0).0,47,19,1000,0,0,0,1,1,10" }
        #expect(Track.parse(rows.joined(separator: "\n"), name: "short") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(Track.parse("hello\nworld\n", name: "junk") == nil)
        #expect(Track.diagnose("hello\nworld\n").contains("NO line matches"))
    }

    // MARK: - Helpers

    @Test(arguments: ["2025-06-01T10:00:00Z", "2025-06-01T10:00:00.5Z",
                      "2025-06-01T10:00:00.50Z", "2025-06-01T10:00:00.5000Z"])
    func isoDateAcceptsAnyFractionPrecision(_ s: String) {
        #expect(Track.isoDate(s) != nil)
    }

    @Test func liveGnssDerivedValues() {
        var g = LiveGNSS()
        g.vN = 30; g.vE = 40; g.vD = 25           // 50 m/s horizontal
        #expect(abs(g.hSpeedKmh - 180) < 0.001)
        #expect(abs(g.vSpeedKmh - 90) < 0.001)
        #expect(abs((g.glideRatio ?? 0) - 2) < 0.001)
        #expect(abs(g.headingDeg - 53.130) < 0.01)
        #expect(!g.hasFix)
    }
}
