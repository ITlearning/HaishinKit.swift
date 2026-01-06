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
    public static let stableCountsThreshold: Int = 15
    private var stableCounts: Int = 0
    
    public let mamimumVideoBitRate: Int
    public var effectiveMaxBitRate: Int
    public var resolutionMaxBitRate: Int
    public let minVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0

    private var initialVideoSize: CGSize?
    private var currentVideoSize: Resolution = .p1080
    private var currentFrameRate: FrameRate = .fps30

    /// 해상도 조절 임계 비트레이트 (기본 1000kbps = 1,000,000bps)
    public let resolutionThresholdBitRate: Int

    /// 비트레이트 저하 후 프레임레이트 조절까지 대기 시간 (초)
    private let frameRateAdjustDelay: Int = 2
    /// 비트레이트 저하 후 경과 시간 추적
    private var degradationWaitCounts: Int = 0
    /// 비트레이트만 조절한 상태인지 추적
    private var isBitRateDegraded: Bool = false

    /// Creates a new instance.
    /// - Parameters:
    ///   - mamimumVideoBitrate: 최대 비디오 비트레이트
    ///   - resolutionThresholdBitRate: 해상도 조절 임계 비트레이트 (기본 1,000,000 = 1000kbps)
    public init(mamimumVideoBitrate: Int, resolutionThresholdBitRate: Int = 1_000_000) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
        self.effectiveMaxBitRate = mamimumVideoBitrate
        self.resolutionMaxBitRate = mamimumVideoBitrate
        self.minVideoBitRate = mamimumVideoBitrate / 4
        self.resolutionThresholdBitRate = resolutionThresholdBitRate
    }

    private func getMaxBitrateForResolution(_ size: CGSize) -> Int {
        guard let initial = initialVideoSize else { return effectiveMaxBitRate }
        let currentPixels = size.width * size.height
        let initialPixels = initial.width * initial.height
        guard initialPixels > 0 else { return effectiveMaxBitRate }
        
        // 픽셀 비율에 따라 비트레이트 계산
        let pixelRatio = currentPixels / initialPixels
        let maxBitrate = Int(Double(mamimumVideoBitRate) * pixelRatio)
        return max(maxBitrate, minVideoBitRate)  // 최소 비트레이트 보장
    }
    
    
    enum ControlResolution {
        case up
        case down
    }
    
    enum Resolution {
        case p1080
        case p720
        case p540

        var size: CGSize {
            switch self {
            case .p1080:
                return .init(width: 1080, height: 1920)
            case .p720:
                return .init(width: 720, height: 1280)
            case .p540:
                return .init(width: 540, height: 960)
            }
        }

        func sizeUp() -> Self {
            switch self {
            case .p1080: return self
            case .p720: return .p1080
            case .p540: return .p720
            }
        }

        func sizeDown() -> Self {
            switch self {
            case .p1080: return .p720
            case .p720: return .p540
            case .p540: return self
            }
        }

        var isLowest: Bool {
            return self == .p540
        }

        var isHighest: Bool {
            return self == .p1080
        }
    }

    enum FrameRate {
        case fps30
        case fps24
        case fps15

        /// frameInterval 값 (1/fps - 0.001)
        var frameInterval: Double {
            switch self {
            case .fps30: return (1.0 / 30.0) - 0.001
            case .fps24: return (1.0 / 24.0) - 0.001
            case .fps15: return (1.0 / 15.0) - 0.001
            }
        }

        var fps: Int {
            switch self {
            case .fps30: return 30
            case .fps24: return 24
            case .fps15: return 15
            }
        }

        func rateUp() -> Self {
            switch self {
            case .fps30: return self
            case .fps24: return .fps30
            case .fps15: return .fps24
            }
        }

        func rateDown() -> Self {
            switch self {
            case .fps30: return .fps24
            case .fps24: return .fps15
            case .fps15: return self
            }
        }

        var isLowest: Bool {
            return self == .fps15
        }

        var isHighest: Bool {
            return self == .fps30
        }
    }
    
    func resolutionSetting(_ control: ControlResolution) {
        let temp = currentVideoSize

        switch control {
        case .up:
            let sizeUp = currentVideoSize.sizeUp()
            currentVideoSize = sizeUp
        case .down:
            let sizeDown = currentVideoSize.sizeDown()
            currentVideoSize = sizeDown
        }

        let maxBitrate = getMaxBitrateForResolution(currentVideoSize.size)
        print("[TABBER] 📺 해상도 \(control == .up ? "UP" : "DOWN" ) : 기존 \(temp.size) --> 변경 \(currentVideoSize.size) | 해상도의 최대 비트레이트 : \(maxBitrate)")
        resolutionMaxBitRate = maxBitrate
    }

    func frameRateSetting(_ control: ControlResolution) {
        let temp = currentFrameRate

        switch control {
        case .up:
            currentFrameRate = currentFrameRate.rateUp()
        case .down:
            currentFrameRate = currentFrameRate.rateDown()
        }

        print("[TABBER] 🎬 프레임레이트 \(control == .up ? "UP" : "DOWN") : 기존 \(temp.fps)fps --> 변경 \(currentFrameRate.fps)fps")
    }

    /// 단계적 품질 저하 - 비트레이트 → 프레임레이트 → 해상도 순서
    func degradeQuality(currentBitRate: Int, videoSettings: inout VideoCodecSettings) -> Bool {
        var needsUpdate = false

        // 1단계: 비트레이트가 이미 낮아진 상태인지 확인
        if !isBitRateDegraded {
            isBitRateDegraded = true
            degradationWaitCounts = 0
            print("[TABBER][1단계] 비트레이트 저하 시작, 프레임레이트 조절 대기 중...")
            return needsUpdate
        }

        // 대기 시간 증가
        degradationWaitCounts += 1

        // 2단계: 프레임레이트 조절 (대기 시간 경과 후)
        if degradationWaitCounts >= frameRateAdjustDelay && !currentFrameRate.isLowest {
            frameRateSetting(.down)
            videoSettings.frameInterval = currentFrameRate.frameInterval
            needsUpdate = true
            degradationWaitCounts = 0  // 다음 단계를 위해 리셋
            print("[TABBER][2단계] 프레임레이트 조절: \(currentFrameRate.fps)fps")
            return needsUpdate
        }

        // 3단계: 해상도 조절 (비트레이트가 임계값 이하이고, 프레임레이트가 최저일 때)
        if currentBitRate <= resolutionThresholdBitRate && currentFrameRate.isLowest && !currentVideoSize.isLowest {
            resolutionSetting(.down)
            videoSettings.videoSize = currentVideoSize.size
            needsUpdate = true
            print("[TABBER][3단계] 해상도 조절: \(currentVideoSize.size)")
        }

        return needsUpdate
    }

    /// 단계적 품질 복구 - 해상도 → 프레임레이트 → 비트레이트 순서 (저하의 역순)
    /// - Returns: (needsUpdate, recoveryType) - 업데이트 필요 여부와 복구 타입
    func recoverQuality(videoSettings: inout VideoCodecSettings) -> (needsUpdate: Bool, recoveryType: String) {
        // 1단계: 해상도 복구 (가장 먼저)
        if !currentVideoSize.isHighest && effectiveMaxBitRate >= resolutionMaxBitRate {
            resolutionSetting(.up)
            videoSettings.videoSize = currentVideoSize.size
            // 해상도 복구 시 resolutionMaxBitRate 업데이트
            resolutionMaxBitRate = getMaxBitrateForResolution(currentVideoSize.size)
            return (true, "해상도")
        }

        // 2단계: 프레임레이트 복구
        if !currentFrameRate.isHighest {
            frameRateSetting(.up)
            videoSettings.frameInterval = currentFrameRate.frameInterval
            return (true, "프레임레이트")
        }

        // 3단계: 비트레이트 복구 (이미 기존 로직에서 처리)
        // 모든 품질이 복구되면 저하 상태 리셋
        if currentVideoSize.isHighest && currentFrameRate.isHighest {
            isBitRateDegraded = false
            degradationWaitCounts = 0
        }

        return (false, "")
    }

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status:
            var videoSettings = await stream.videoSettings
            
            if initialVideoSize == nil {
                initialVideoSize = videoSettings.videoSize
            }
            
            let maxRecoveryBitRate = Int(Double(effectiveMaxBitRate) * 0.9) // 상한의 90%
            
            if videoSettings.bitRate < maxRecoveryBitRate {
                // 아직 90% 미만이면: 비트레이트를 10%씩 복구
                stableCounts = 0  // 아직 완전 안정 상태는 아님
                
                let incremental = effectiveMaxBitRate / 10
                let temp = min(videoSettings.bitRate + incremental, maxRecoveryBitRate)
                videoSettings.bitRate = temp
                print("[TABBER][복구 🔄] 비트레이트 조정 ---------> \(temp) (상한의 90%: \(maxRecoveryBitRate))")
                sufficientBWCounts = 0
                
                try? await stream.setVideoSettings(videoSettings)
            } else {
                // 이미 상한의 90% 근처에서 안정적으로 보내는 구간
                sufficientBWCounts = 0
                stableCounts += 1

                // 15초 이상 안정 + 아직 최종 목표치보다 낮으면 상한 10% 올리기
                if stableCounts >= Self.stableCountsThreshold && effectiveMaxBitRate < mamimumVideoBitRate {
                    let newMax = min(Int(Double(effectiveMaxBitRate) * 1.1), mamimumVideoBitRate)
                    effectiveMaxBitRate = newMax
                    stableCounts = 0

                    print("[TABBER][📈 15초 안정 → 목표 상향] effectiveMaxBitRate ---------> \(effectiveMaxBitRate)")

                    // 단계적 품질 복구 (해상도 → 프레임레이트 순서)
                    let (needsUpdate, recoveryType) = recoverQuality(videoSettings: &videoSettings)
                    if needsUpdate {
                        print("[TABBER][복구 🔄] \(recoveryType) 복구 완료")
                        do {
                            try await stream.setVideoSettings(videoSettings)
                        } catch {
                            print("[TABBER] \(recoveryType) 복구 적용 실패 \(error.localizedDescription)")
                        }
                    }
                }
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBWCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            let currentBitRate = videoSettings.bitRate
            
            if 0 < report.currentBytesOutPerSecond {
                let bitRate = Int(report.currentBytesOutPerSecond * 8) / (zeroBytesOutPerSecondCounts + 1)
                let estimated = bitRate - audioSettings.bitRate
                let currentBandwidth = Int(report.currentBytesOutPerSecond * 8)
                let bandwidthRatio = Double(currentBandwidth) / Double(currentBitRate)
                
                
                let queueThreshold: Int = 100_000  // 100KB (임계값 조정 가능)
                let queueTooLarge = report.currentQueueBytesOut > queueThreshold
                
                if bandwidthRatio >= 0.8 && !queueTooLarge {
                    // 실제 대역폭 충분 + 큐도 적당함 → 무시
                    print("[TABBER][⚠️ 일시적 큐 증가] 실제 대역폭 충분 (\(Int(bandwidthRatio * 100))%), 큐 적정 → 조정 안함")
                    return
                }
                
                
                let newMax = max(estimated, minVideoBitRate)
                effectiveMaxBitRate = newMax
                let temp = Int(Double(effectiveMaxBitRate) * 0.9)
                
                if queueTooLarge {
                    print("[TABBER][❌ 큐 과다!!] 큐 크기: \(report.currentQueueBytesOut / 1024)KB → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                } else {
                    print("[TABBER][❌ 대역폭 부족!!] 실제 대역폭: \(Int(bandwidthRatio * 100))% → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                }
                
                videoSettings.bitRate = temp

                // 단계적 품질 저하 적용 (비트레이트 → 프레임레이트 → 해상도)
                _ = degradeQuality(currentBitRate: temp, videoSettings: &videoSettings)

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
            resolutionMaxBitRate = mamimumVideoBitRate
            videoSettings.bitRate = mamimumVideoBitRate
            // 상태 초기화
            currentVideoSize = .p1080
            currentFrameRate = .fps30
            isBitRateDegraded = false
            degradationWaitCounts = 0
            stableCounts = 0
            if let initialSize = initialVideoSize {
                videoSettings.videoSize = initialSize
            }
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}
