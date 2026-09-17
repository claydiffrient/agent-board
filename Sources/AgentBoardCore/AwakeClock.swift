import Foundation

/// The two readings a deadline needs: the wall clock the database stores its timestamps on, and
/// Darwin's `CLOCK_UPTIME_RAW`, which stops advancing while the system is asleep.
public protocol SystemClock: Sendable {
    var wallMillis: Int64 { get }
    var uptimeSeconds: TimeInterval { get }
}

public struct DarwinClock: SystemClock {
    public init() {}

    public var wallMillis: Int64 { .nowMillis }

    /// `CLOCK_MONOTONIC` and `CLOCK_MONOTONIC_RAW` both keep counting through a suspend on Darwin;
    /// only `CLOCK_UPTIME_RAW` does not. Measured on macOS 25.6: 20.3 days since `kern.boottime`,
    /// `CLOCK_MONOTONIC` 1_752_842s, `CLOCK_UPTIME_RAW` 666_698s.
    public var uptimeSeconds: TimeInterval {
        var t = timespec()
        clock_gettime(CLOCK_UPTIME_RAW, &t)
        return TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1_000_000_000
    }
}

/// One stretch the machine spent suspended, placed on the wall clock.
public struct ObservedSleep: Sendable, Equatable {
    public let endedAtMillis: Int64
    public let millis: Int64

    public init(endedAtMillis: Int64, millis: Int64) {
        self.endedAtMillis = endedAtMillis
        self.millis = max(0, millis)
    }

    public var startedAtMillis: Int64 { endedAtMillis - millis }

    func overlapMillis(from: Int64, to: Int64) -> Int64 {
        max(0, min(endedAtMillis, to) - max(startedAtMillis, from))
    }
}

/// A clock reading that can say how much of the time since some past timestamp the machine was
/// actually awake. Deadlines meant to bound an agent's *work* are measured against this; deadlines
/// meant to bound calendar time — archive retention — stay on the wall clock.
public struct AwakeElapsed: Sendable, Equatable {
    public let nowMillis: Int64
    public let sleeps: [ObservedSleep]

    public init(nowMillis: Int64, sleeps: [ObservedSleep] = []) {
        self.nowMillis = nowMillis
        self.sleeps = sleeps
    }

    public init(now: Date, sleeps: [ObservedSleep] = []) {
        self.init(nowMillis: Int64(now.timeIntervalSince1970 * 1000), sleeps: sleeps)
    }

    public var now: Date { nowMillis.asDate }

    public func millisAwake(since: Int64) -> Int64 {
        let elapsed = nowMillis - since
        guard elapsed > 0 else { return 0 }
        let slept = sleeps.reduce(Int64(0)) { $0 + $1.overlapMillis(from: since, to: nowMillis) }
        return max(0, elapsed - slept)
    }

    public func secondsAwake(since: Date) -> TimeInterval {
        TimeInterval(millisAwake(since: Int64(since.timeIntervalSince1970 * 1000))) / 1000
    }
}

/// Detects system sleep by sampling both clocks: wall time advances through a suspend and
/// `CLOCK_UPTIME_RAW` does not, so the gap between the two deltas is how long the machine slept.
///
/// Every reading samples, so a caller that runs before the next metering tick still sees the
/// suspend that just ended.
public final class SleepLedger: @unchecked Sendable {
    public static let shared = SleepLedger()

    /// Below this the gap is scheduler jitter and clock drift, not a suspend.
    public static let minimumSleepMillis: Int64 = 2_000
    /// No deadline measured on this clock reaches back further, and sleeps accrue a handful a day.
    static let retentionMillis: Int64 = 7 * 24 * 60 * 60 * 1000

    private let clock: any SystemClock
    private let lock = NSLock()
    private var sleeps: [ObservedSleep] = []
    private var previous: (wallMillis: Int64, uptimeSeconds: TimeInterval)?

    public init(clock: any SystemClock = DarwinClock()) {
        self.clock = clock
    }

    @discardableResult
    public func reading() -> AwakeElapsed {
        let sampled = sample()
        return AwakeElapsed(nowMillis: sampled.wallMillis, sleeps: sampled.sleeps)
    }

    /// The same ledger paired with a caller's own `now` — for a view whose timer-driven `now` is
    /// what re-renders it.
    public func reading(asOf now: Date) -> AwakeElapsed {
        AwakeElapsed(now: now, sleeps: sample().sleeps)
    }

    private func sample() -> (wallMillis: Int64, sleeps: [ObservedSleep]) {
        let wall = clock.wallMillis
        let uptime = clock.uptimeSeconds
        lock.lock()
        defer { lock.unlock() }
        if let previous {
            let slept = (wall - previous.wallMillis) - Int64((uptime - previous.uptimeSeconds) * 1000)
            if slept >= Self.minimumSleepMillis {
                sleeps.append(ObservedSleep(endedAtMillis: wall, millis: slept))
                sleeps.removeAll { $0.endedAtMillis < wall - Self.retentionMillis }
            }
        }
        previous = (wall, uptime)
        return (wall, sleeps)
    }
}
