import Foundation

/// App-wide, stored in `UserDefaults` beside the other Settings panes. SPEC §14.1.
public struct DiskSpaceSettings: Sendable, Equatable {
    public var enabled: Bool
    public var lowThresholdGB: Int
    public var rearmThresholdGB: Int
    public var checkIntervalMinutes: Int

    public static let defaults = DiskSpaceSettings()

    public static let enabledKey = "diskSpace.enabled"
    public static let lowThresholdKey = "diskSpace.lowThresholdGB"
    public static let rearmThresholdKey = "diskSpace.rearmThresholdGB"
    public static let intervalKey = "diskSpace.checkIntervalMinutes"

    public init(enabled: Bool = true, lowThresholdGB: Int = 25, rearmThresholdGB: Int = 35, checkIntervalMinutes: Int = 5) {
        self.enabled = enabled
        self.lowThresholdGB = lowThresholdGB
        self.rearmThresholdGB = rearmThresholdGB
        self.checkIntervalMinutes = checkIntervalMinutes
    }

    public static func load(_ defaults: UserDefaults = .standard) -> DiskSpaceSettings {
        let d = DiskSpaceSettings.defaults
        return DiskSpaceSettings(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? d.enabled,
            lowThresholdGB: defaults.object(forKey: lowThresholdKey) as? Int ?? d.lowThresholdGB,
            rearmThresholdGB: defaults.object(forKey: rearmThresholdKey) as? Int ?? d.rearmThresholdGB,
            checkIntervalMinutes: defaults.object(forKey: intervalKey) as? Int ?? d.checkIntervalMinutes
        )
    }

    var lowBytes: Int64 { Int64(max(lowThresholdGB, 0)) * DiskSpace.bytesPerGB }
    /// A rearm at or below the low threshold would fire on every check, so it never drops under it.
    var rearmBytes: Int64 { max(Int64(max(rearmThresholdGB, 0)) * DiskSpace.bytesPerGB, lowBytes) }
    var intervalSeconds: TimeInterval { TimeInterval(max(checkIntervalMinutes, 1) * 60) }
}

public enum DiskSpace {
    public static let bytesPerGB: Int64 = 1_000_000_000

    public static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / Double(bytesPerGB))
    }
}

/// One mounted volume's free space, keyed by its mount point so two paths on it count once.
public struct VolumeSpace: Sendable, Equatable {
    public var mountPoint: String
    public var name: String
    public var availableBytes: Int64

    public init(mountPoint: String, name: String, availableBytes: Int64) {
        self.mountPoint = mountPoint
        self.name = name
        self.availableBytes = availableBytes
    }
}

public struct LowDiskSpaceEvent: Sendable, Equatable {
    public var volume: VolumeSpace
    public var lowThresholdGB: Int

    public var title: String { "Low disk space" }
    public var body: String {
        "\(volume.name) has \(DiskSpace.gigabytes(volume.availableBytes)) GB free, below \(lowThresholdGB) GB."
    }
}

public protocol DiskSpaceMeasuring: Sendable {
    /// The distinct volumes holding `paths`. A path that does not exist yet is measured at its
    /// nearest existing ancestor.
    func volumes(holding paths: [URL]) -> [VolumeSpace]
}

public struct SystemDiskSpace: DiskSpaceMeasuring {
    public init() {}

    public func volumes(holding paths: [URL]) -> [VolumeSpace] {
        var seen: Set<String> = []
        var result: [VolumeSpace] = []
        for path in paths {
            guard let volume = measure(Self.nearestExisting(path)), seen.insert(volume.mountPoint).inserted else { continue }
            result.append(volume)
        }
        return result
    }

    private func measure(_ url: URL) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeNameKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let mount = values.volume,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeSpace(mountPoint: mount.path, name: values.volumeName ?? mount.path, availableBytes: available)
    }

    static func nearestExisting(_ url: URL) -> URL {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            current = current.deletingLastPathComponent()
        }
        return current
    }
}

/// Fires one `LowDiskSpaceEvent` when a volume drops below the low threshold, then stays quiet for
/// that volume until it has risen above the rearm threshold. Checks are spaced on
/// `CLOCK_UPTIME_RAW`, so a Mac waking from sleep does not owe a burst of them. SPEC §14.
@MainActor
public final class DiskSpaceMonitor {
    private let measurer: any DiskSpaceMeasuring
    private let clock: any SystemClock
    private let settings: @MainActor () -> DiskSpaceSettings
    private var lastCheckUptime: TimeInterval?
    /// Mount points that already fired and have not yet climbed back above the rearm threshold.
    private var fired: Set<String> = []

    public init(
        measurer: any DiskSpaceMeasuring = SystemDiskSpace(),
        clock: any SystemClock = DarwinClock(),
        settings: @escaping @MainActor () -> DiskSpaceSettings = { DiskSpaceSettings.load() }
    ) {
        self.measurer = measurer
        self.clock = clock
        self.settings = settings
    }

    /// Measures only when an interval of awake time has passed since the last measurement; the
    /// first call measures at once.
    public func tick(paths: @autoclosure () -> [URL]) -> [LowDiskSpaceEvent] {
        let settings = settings()
        guard settings.enabled else {
            fired = []
            lastCheckUptime = nil
            return []
        }
        let uptime = clock.uptimeSeconds
        if let lastCheckUptime, uptime - lastCheckUptime < settings.intervalSeconds { return [] }
        lastCheckUptime = uptime
        return evaluate(measurer.volumes(holding: paths()), settings: settings)
    }

    private func evaluate(_ volumes: [VolumeSpace], settings: DiskSpaceSettings) -> [LowDiskSpaceEvent] {
        var events: [LowDiskSpaceEvent] = []
        for volume in volumes {
            if fired.contains(volume.mountPoint) {
                if volume.availableBytes > settings.rearmBytes { fired.remove(volume.mountPoint) }
            } else if volume.availableBytes < settings.lowBytes {
                fired.insert(volume.mountPoint)
                events.append(LowDiskSpaceEvent(volume: volume, lowThresholdGB: settings.lowThresholdGB))
            }
        }
        return events
    }
}
