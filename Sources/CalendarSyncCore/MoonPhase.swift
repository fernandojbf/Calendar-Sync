import Foundation

/// The moon's phase on a date, for the menu bar icon. Pure logic, unit tested.
public enum MoonPhase: CaseIterable, Hashable, Sendable {
    case newMoon, waxingCrescent, firstQuarter, waxingGibbous, fullMoon, waningGibbous, lastQuarter, waningCrescent

    /// The phase's name, e.g. "Waxing gibbous".
    public var name: String {
        switch self {
        case .newMoon: "New moon"
        case .waxingCrescent: "Waxing crescent"
        case .firstQuarter: "First quarter"
        case .waxingGibbous: "Waxing gibbous"
        case .fullMoon: "Full moon"
        case .waningGibbous: "Waning gibbous"
        case .lastQuarter: "Last quarter"
        case .waningCrescent: "Waning crescent"
        }
    }

    /// The phase on `date`. Each of the four principal phases covers the eighth of the cycle
    /// centred on its instant, so a full moon shows for about 3.7 days; the crescent and
    /// gibbous phases fill the eighths between.
    public static func phase(on date: Date) -> MoonPhase {
        let eighths = Int((elongation(on: date) / 45).rounded())
        return allCases[eighths % 8]
    }

    /// How far the moon has gone round its cycle, as its elongation from the sun in degrees:
    /// 0 at new moon, 90 at first quarter, 180 at full moon and 270 at last quarter. Low
    /// precision geocentric ecliptic longitudes with the largest periodic terms (Meeus,
    /// Astronomical Algorithms, chapters 25 and 47): within about a quarter of an hour of the
    /// published phase times.
    static func elongation(on date: Date) -> Double {
        let d = date.timeIntervalSince(j2000) / 86400
        let sunAnomaly = 357.5291 + 0.98560028 * d
        let sun = 280.4665 + 0.98564736 * d + 1.9148 * sine(sunAnomaly) + 0.0200 * sine(2 * sunAnomaly)
        let meanLongitude = 218.3165 + 13.17639648 * d
        let anomaly = 134.9634 + 13.06499295 * d
        let meanElongation = 297.8502 + 12.19074912 * d
        let latitudeArgument = 93.2721 + 13.22935024 * d
        let moon = meanLongitude
            + 6.2888 * sine(anomaly)
            + 1.2740 * sine(2 * meanElongation - anomaly)
            + 0.6583 * sine(2 * meanElongation)
            + 0.2136 * sine(2 * anomaly)
            - 0.1851 * sine(sunAnomaly)
            - 0.1143 * sine(2 * latitudeArgument)
            + 0.0588 * sine(2 * meanElongation - 2 * anomaly)
            + 0.0572 * sine(2 * meanElongation - sunAnomaly - anomaly)
            + 0.0533 * sine(2 * meanElongation + anomaly)
        let elongation = (moon - sun).truncatingRemainder(dividingBy: 360)
        return elongation < 0 ? elongation + 360 : elongation
    }

    /// The epoch the longitudes count from: J2000.0, 1 January 2000 at noon UTC.
    private static let j2000 = Date(timeIntervalSince1970: 946_728_000)

    private static func sine(_ degrees: Double) -> Double {
        sin(degrees * .pi / 180)
    }
}
