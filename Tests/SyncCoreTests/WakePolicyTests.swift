import Foundation
import Testing

@testable import SyncCore

struct WakePolicyTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func restores(slept: Date, woke: Date) -> Bool {
        WakePolicy.shouldRestoreLights(sleptAt: slept, wokeAt: woke, calendar: calendar)
    }

    @Test func eveningSleepThenMorningWakeStaysOff() {
        #expect(!restores(slept: date(day: 9, hour: 23), woke: date(day: 10, hour: 9)))
    }

    @Test func sleepAfterMidnightThenDaytimeWakeStaysOff() {
        #expect(!restores(slept: date(day: 10, hour: 2), woke: date(day: 10, hour: 11)))
    }

    @Test func sleepingAWholeWeekendStaysOff() {
        #expect(!restores(slept: date(day: 6, hour: 22), woke: date(day: 8, hour: 13)))
    }

    @Test func napDuringTheDayRestores() {
        #expect(restores(slept: date(day: 10, hour: 9), woke: date(day: 10, hour: 14)))
    }

    @Test func wakingBeforeDaybreakRestores() {
        #expect(restores(slept: date(day: 9, hour: 23), woke: date(day: 10, hour: 6, minute: 30)))
    }

    @Test func wakingTheNextEveningRestores() {
        #expect(restores(slept: date(day: 9, hour: 23), woke: date(day: 10, hour: 18)))
    }

    @Test func shortEveningSleepRestores() {
        #expect(restores(slept: date(day: 10, hour: 20), woke: date(day: 10, hour: 21)))
    }

    @Test func daytimeEndsAtFour() {
        #expect(!restores(slept: date(day: 9, hour: 23), woke: date(day: 10, hour: 15, minute: 59)))
        #expect(restores(slept: date(day: 9, hour: 23), woke: date(day: 10, hour: 16)))
    }
}
