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
    public static let statusCountsThreshold: Int = 45
    public static let stableCountsThreshold: Int = 120
    private var stableCounts: Int = 0
    
    public let mamimumVideoBitRate: Int
    public var effectiveMaxBitRate: Int
    public let minVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0

    /// Creates a new instance.
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
        self.effectiveMaxBitRate = mamimumVideoBitrate
        self.minVideoBitRate = mamimumVideoBitrate / 4
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            let maxRecoveryBitRate = Int(Double(effectiveMaxBitRate) * 0.9) // 상한의 90%
            
            if videoSettings.bitRate < maxRecoveryBitRate {
                // 아직 90% 미만이면: 비트레이트를 10%씩 복구
                stableCounts = 0  // 아직 완전 안정 상태는 아님
                if Self.statusCountsThreshold <= sufficientBWCounts {
                    let incremental = effectiveMaxBitRate / 10
                    let temp = min(videoSettings.bitRate + incremental, maxRecoveryBitRate)
                    videoSettings.bitRate = temp
                    print("[복구 🔄] 비트레이트 조정 ---------> \(temp) (상한의 90%: \(maxRecoveryBitRate))")
                    try? await stream.setVideoSettings(videoSettings)
                    sufficientBWCounts = 0
                } else {
                    sufficientBWCounts += 1
                }
            } else {
                // 이미 상한의 90% 근처에서 안정적으로 보내는 구간
                sufficientBWCounts = 0
                stableCounts += 1
                
                // 5분(300초) 이상 안정 + 아직 최종 목표치보다 낮으면 상한 10% 올리기
                if stableCounts >= Self.stableCountsThreshold && effectiveMaxBitRate < mamimumVideoBitRate {
                    let newMax = min(Int(Double(effectiveMaxBitRate) * 1.1), mamimumVideoBitRate)
                    effectiveMaxBitRate = newMax
                    stableCounts = 0
                    print("[📈 2분 안정 → 목표 상향] effectiveMaxBitRate ---------> \(effectiveMaxBitRate)")
                }
                
                if stableCounts % 5 == 0 {
                    let minutes = stableCounts / 60
                    let seconds = stableCounts % 60
                    print("[안정 상태] ==> \(minutes) : \(seconds) 경과")
                }
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBWCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            if 0 < report.currentBytesOutPerSecond {
                let bitRate = Int(report.currentBytesOutPerSecond * 8) / (zeroBytesOutPerSecondCounts + 1)
                let estimated = bitRate - audioSettings.bitRate

                let temp = min(
                    max(estimated, minVideoBitRate),
                    effectiveMaxBitRate
                )
                
                effectiveMaxBitRate = max(temp, minVideoBitRate)
                
                print("[❌ 대역폭 부족!!] 비트레이트 조정 ---------> \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                videoSettings.bitRate = temp
                videoSettings.frameInterval = VideoCodecSettings.frameInterval30
                sufficientBWCounts = 0
                stableCounts = 0
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
            effectiveMaxBitRate = mamimumVideoBitRate
            videoSettings.bitRate = mamimumVideoBitRate
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
