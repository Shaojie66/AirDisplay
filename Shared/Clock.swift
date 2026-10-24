import Foundation

enum Clock {
    /// 单调时钟，纳秒（和 mach_absolute_time 同源）
    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// mach_absolute_time 刻度 → 纳秒
    static func machToNs(_ t: UInt64) -> UInt64 {
        t * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
