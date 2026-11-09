import Foundation

/// Decides whether waking the Mac should bring back the lights that sleep switched off.
///
/// Waking during the day after the Mac slept through the night leaves them off: the lights were last on
/// for the evening, and daylight doesn't need them. Any other wake brings them back.
public enum WakePolicy {
    /// Daytime runs from this hour...
    public static let dayStartHour = 7
    /// ...until this one. Early, so a dark winter afternoon still gets the lights back.
    public static let dayEndHour = 16

    /// - Parameters:
    ///   - sleptAt: When the lights were switched off for sleep.
    ///   - wokeAt: When the displays woke.
    public static func shouldRestoreLights(
        sleptAt: Date, wokeAt: Date, calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: wokeAt)
        guard hour >= dayStartHour, hour < dayEndHour,
            let dayStart = calendar.date(bySettingHour: dayStartHour, minute: 0, second: 0, of: wokeAt)
        else { return true }
        // Slept through the night: since before this morning began.
        return sleptAt >= dayStart
    }
}
