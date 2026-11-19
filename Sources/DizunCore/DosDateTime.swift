import Foundation

/// DOS date/time is the ZIP format's timestamp: 2-second granularity, years
/// 1980–2107, stored as two UInt16 bitfields. DOS fields carry no timezone;
/// DIZUN reads and writes them as UTC so results are deterministic across
/// machines (The Unarchiver treats them as local — a documented divergence).
enum DosDateTime {
    static func pack(_ date: Date) -> (date: UInt16, time: UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = min(max(c.year ?? 1980, 1980), 2107)
        let month = min(max(c.month ?? 1, 1), 12)
        let day = min(max(c.day ?? 1, 1), 31)
        let hour = min(c.hour ?? 0, 23)
        let minute = min(c.minute ?? 0, 59)
        let second = min(c.second ?? 0, 59)
        let dosDate = UInt16((year - 1980) << 9 | month << 5 | day)
        let dosTime = UInt16(hour << 11 | minute << 5 | second / 2)
        return (dosDate, dosTime)
    }

    /// Nil when the stored fields are impossible (month 0, hour 31, …).
    static func unpack(date: UInt16, time: UInt16) -> Date? {
        let year = Int(date >> 9) + 1980
        let month = Int((date >> 5) & 0xF)
        let day = Int(date & 0x1F)
        let hour = Int(time >> 11)
        let minute = Int((time >> 5) & 0x3F)
        let second = Int((time & 0x1F) * 2)
        guard (1980...2107).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: year, month: month, day: day,
                                             hour: hour, minute: minute, second: second))
    }
}
