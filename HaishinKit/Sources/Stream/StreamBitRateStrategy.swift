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
                let temp = min(videoSettings.bitRate + incremental, mamimumVideoBitRate)
                videoSettings.bitRate = temp
                print("[복구 된 후 🔄] 비트레이트 조정 ---------> \(temp)")
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
                let estimated = bitRate - audioSettings.bitRate
                let temp = min(
                    max(estimated, mamimumVideoBitRate / 10),
                    mamimumVideoBitRate
                )
                print("[❌ 대역폭 부족!!] 비트레이트 조정 ---------> \(temp)")
                videoSettings.bitRate = temp
                videoSettings.frameInterval = VideoCodecSettings.frameInterval30
                sufficientBWCounts = 0
                zeroBytesOutPerSecondCounts = 0
                try? await stream.setVideoSettings(videoSettings)
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
        }
    }
}
