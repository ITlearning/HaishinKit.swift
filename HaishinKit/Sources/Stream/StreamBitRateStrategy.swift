import Foundation

/// A type with a network bitrate strategy representation.
public protocol StreamBitRateStrategy: Sendable {
    /// The mamimum video bitRate.
    var mamimumVideoBitRate: Int { get }
    /// The mamimum audio bitRate.
    var mamimumAudioBitRate: Int { get }

    /// Adjust a bitRate.
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async
}

/// A delegate protocol for receiving buffer drop events.
public protocol StreamBufferDropDelegate: AnyObject, Sendable {
    /// Called when buffer clearing starts.
    /// - Parameters:
    ///   - strategy: The strategy that initiated the buffer clear.
    ///   - estimatedDelaySeconds: The estimated delay in seconds before clearing.
    func bufferDropStrategyDidStartClearing(_ strategy: StreamBufferDropBitRateStrategy, estimatedDelaySeconds: Double) async

    /// Called when buffer clearing completes and streaming resumes from keyframe.
    /// - Parameter strategy: The strategy that completed the buffer clear.
    func bufferDropStrategyDidFinishClearing(_ strategy: StreamBufferDropBitRateStrategy) async

    /// Called when waiting for keyframe to resume streaming.
    /// - Parameter strategy: The strategy that is waiting for keyframe.
    func bufferDropStrategyWaitingForKeyframe(_ strategy: StreamBufferDropBitRateStrategy) async
}

/// An actor provides an algorithm that focuses on video bitrate control.
public final actor StreamVideoAdaptiveBitRateStrategy: StreamBitRateStrategy {
    /// The status counts threshold for restoring the status
    public static let statusCountsThreshold: Int = 15

    public let mamimumVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0

    /// Creates a new instance.
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            if videoSettings.bitRate == mamimumVideoBitRate {
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 10
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
                try? await stream.setVideoSettings(videoSettings)
                sufficientBWCounts = 0
            } else {
                sufficientBWCounts += 1
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBWCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            if 0 < report.currentBytesOutPerSecond {
                let bitRate = Int(report.currentBytesOutPerSecond * 8) / (zeroBytesOutPerSecondCounts + 1)
                videoSettings.bitRate = max(bitRate - audioSettings.bitRate, mamimumVideoBitRate / 10)
                videoSettings.frameInterval = 0.0
                sufficientBWCounts = 0
                zeroBytesOutPerSecondCounts = 0
            } else {
                switch zeroBytesOutPerSecondCounts {
                case 2:
                    videoSettings.frameInterval = VideoCodecSettings.frameInterval10
                case 4:
                    videoSettings.frameInterval = VideoCodecSettings.frameInterval05
                default:
                    break
                }
                try? await stream.setVideoSettings(videoSettings)
                zeroBytesOutPerSecondCounts += 1
            }
        case .reset:
            var videoSettings = await stream.videoSettings
            zeroBytesOutPerSecondCounts = 0
            videoSettings.bitRate = mamimumVideoBitRate
            try? await stream.setVideoSettings(videoSettings)
        case .bufferDelayExceeded:
            // This strategy does not handle buffer delay events
            break
        }
    }
}

/// An actor provides buffer drop functionality when network delay exceeds threshold.
///
/// This strategy monitors the buffer delay and when it exceeds the configured threshold,
/// it drops buffered frames and waits for the next keyframe to resume streaming.
/// This prevents the stream from accumulating excessive delay (e.g., 7 minutes delay).
///
/// ## Usage
/// ```swift
/// let strategy = StreamBufferDropBitRateStrategy(
///     bufferDelayThreshold: 30.0,  // 30 seconds (default)
///     mamimumVideoBitrate: 2_000_000
/// )
/// strategy.delegate = self
/// stream.setBitRateStrategy(strategy)
/// ```
public final actor StreamBufferDropBitRateStrategy: StreamBitRateStrategy {
    /// The state of buffer drop process.
    public enum State: Sendable {
        /// Normal streaming state.
        case streaming
        /// Waiting for next keyframe to resume streaming. Non-keyframes are dropped during this state.
        case waitingForKeyframe
    }

    /// The status counts threshold for restoring the status.
    public static let statusCountsThreshold: Int = 15

    /// The maximum video bitrate.
    public let mamimumVideoBitRate: Int
    /// The maximum audio bitrate.
    public let mamimumAudioBitRate: Int = 0

    /// The current state of the buffer drop strategy.
    public private(set) var state: State = .streaming

    /// The delegate to receive buffer drop events.
    public weak var delegate: (any StreamBufferDropDelegate)?

    /// The buffer delay threshold in seconds. Default is 30 seconds.
    public let bufferDelayThreshold: Double

    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0
    private var keyframeReceived = false

    /// Creates a new instance.
    /// - Parameters:
    ///   - bufferDelayThreshold: The delay threshold in seconds. Default is 30 seconds.
    ///   - mamimumVideoBitrate: The maximum video bitrate.
    public init(bufferDelayThreshold: Double = 30.0, mamimumVideoBitrate: Int) {
        self.bufferDelayThreshold = bufferDelayThreshold
        self.mamimumVideoBitRate = mamimumVideoBitrate
    }

    /// Sets the delegate for receiving buffer drop events.
    public func setDelegate(_ delegate: (any StreamBufferDropDelegate)?) {
        self.delegate = delegate
    }

    /// Notifies that a keyframe has been received, allowing streaming to resume.
    public func notifyKeyframeReceived() {
        guard state == .waitingForKeyframe else { return }
        keyframeReceived = true
        logger.info("[NetworkMonitor] Keyframe received, resuming stream")
    }

    /// Resets the strategy state to normal streaming.
    public func resetState() {
        state = .streaming
        keyframeReceived = false
        logger.info("[NetworkMonitor] State reset to streaming")
    }

    /// Returns whether the strategy is waiting for a keyframe.
    public var isWaitingForKeyframe: Bool {
        state == .waitingForKeyframe
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            // Check if we're waiting for keyframe and one was received
            if state == .waitingForKeyframe && keyframeReceived {
                state = .streaming
                keyframeReceived = false
                await stream.setWaitingForKeyframe(false)
                logger.info("[NetworkMonitor] Streaming resumed after keyframe, queueBytesOut=\(report.currentQueueBytesOut)")
                await delegate?.bufferDropStrategyDidFinishClearing(self)
            }

            // Normal adaptive bitrate logic
            guard state == .streaming else { return }

            var videoSettings = await stream.videoSettings
            if videoSettings.bitRate == mamimumVideoBitRate {
                return
            }
            if Self.statusCountsThreshold <= sufficientBWCounts {
                let incremental = mamimumVideoBitRate / 10
                videoSettings.bitRate = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
                try? await stream.setVideoSettings(videoSettings)
                sufficientBWCounts = 0
                logger.info("[NetworkMonitor] Increased bitrate to \(videoSettings.bitRate)")
            } else {
                sufficientBWCounts += 1
            }

        case .publishInsufficientBWOccured(let report):
            guard state == .streaming else { return }

            sufficientBWCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            if 0 < report.currentBytesOutPerSecond {
                let bitRate = Int(report.currentBytesOutPerSecond * 8) / (zeroBytesOutPerSecondCounts + 1)
                videoSettings.bitRate = max(bitRate - audioSettings.bitRate, mamimumVideoBitRate / 10)
                videoSettings.frameInterval = 0.0
                sufficientBWCounts = 0
                zeroBytesOutPerSecondCounts = 0
                logger.info("[NetworkMonitor] Adjusted bitrate to \(videoSettings.bitRate) due to insufficient bandwidth")
            } else {
                switch zeroBytesOutPerSecondCounts {
                case 2:
                    videoSettings.frameInterval = VideoCodecSettings.frameInterval10
                    logger.info("[NetworkMonitor] Set frame interval to 10fps")
                case 4:
                    videoSettings.frameInterval = VideoCodecSettings.frameInterval05
                    logger.info("[NetworkMonitor] Set frame interval to 5fps")
                default:
                    break
                }
                try? await stream.setVideoSettings(videoSettings)
                zeroBytesOutPerSecondCounts += 1
            }

        case .bufferDelayExceeded(let report, let estimatedDelaySeconds):
            guard state == .streaming else { return }

            logger.info("[NetworkMonitor] Buffer delay exceeded threshold: \(estimatedDelaySeconds)s, starting to drop frames until keyframe")
            state = .waitingForKeyframe
            keyframeReceived = false

            // Set stream to drop non-keyframe video frames
            await stream.setWaitingForKeyframe(true)

            await delegate?.bufferDropStrategyDidStartClearing(self, estimatedDelaySeconds: estimatedDelaySeconds)
            logger.info("[NetworkMonitor] Dropping frames until next keyframe. queueBytesOut=\(report.currentQueueBytesOut)")
            await delegate?.bufferDropStrategyWaitingForKeyframe(self)

        case .reset:
            var videoSettings = await stream.videoSettings
            zeroBytesOutPerSecondCounts = 0
            videoSettings.bitRate = mamimumVideoBitRate
            try? await stream.setVideoSettings(videoSettings)
            state = .streaming
            keyframeReceived = false
            logger.info("[NetworkMonitor] Strategy reset, bitrate restored to \(mamimumVideoBitRate)")
        }
    }
}
