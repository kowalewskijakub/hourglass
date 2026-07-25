import Testing
import Foundation
@testable import HourglassCore

@Suite struct TimeFormattingTests {

    @Test func clockFormatsMinutesAndSeconds() {
        #expect(TimeFormatting.clock(1500) == "25:00")
        #expect(TimeFormatting.clock(0) == "00:00")
        #expect(TimeFormatting.clock(59) == "00:59")
        #expect(TimeFormatting.clock(61) == "01:01")
    }

    @Test func clockClampsNegativesToZero() {
        #expect(TimeFormatting.clock(-5) == "00:00")
    }

    @Test func clockRoundsUpSoFullTimersReadWhole() {
        #expect(TimeFormatting.clock(0.2) == "00:01")
        #expect(TimeFormatting.clock(1499.5) == "25:00")
    }

    @Test func humanDurationReadsNaturally() {
        #expect(TimeFormatting.humanDuration(90 * 60) == "1h 30m")
        #expect(TimeFormatting.humanDuration(45 * 60) == "45m")
        #expect(TimeFormatting.humanDuration(3600) == "1h")
        #expect(TimeFormatting.humanDuration(30) == "30s")
    }
}
