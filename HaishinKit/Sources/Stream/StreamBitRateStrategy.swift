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
    public static let stableCountsThreshold: Int = 5 // 원래 : 180초 | 테스트용 : 30초
    private var stableCounts: Int = 0
    
    public let mamimumVideoBitRate: Int
    public var effectiveMaxBitRate: Int
    public let minVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    private var sufficientBWCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0

    // 비디오 전용 전송 속도 EMA (bytes/sec)
    private var emaVideoBytesPerSecond: Double = 0
    private let emaAlpha: Double = 0.2

    // 복구 보류 중 큐 증가 감지용
    private var lastQueueBytesOut: Int = 0
    private var queueIncreasingCount: Int = 0 // 연속으로 큐가 증가한 횟수

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
        self.minVideoBitRate = 100_000
        self.resolutionThresholdBitRate = resolutionThresholdBitRate
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
        print("[TABBER] 📺 해상도 \(control == .up ? "UP" : "DOWN" ) : 기존 \(temp.size) --> 변경 \(currentVideoSize.size)")
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

    private func updateEmaVideoBytesPerSecond(currentBytesOutPerSecond: Int, audioBitRate: Int) {
        let audioBytesPerSecond = max(audioBitRate / 8, 0)
        let rawVideoBytesPerSecond = max(currentBytesOutPerSecond - audioBytesPerSecond, 0)
        let current = Double(rawVideoBytesPerSecond)

        if emaVideoBytesPerSecond <= 0 {
            emaVideoBytesPerSecond = current
        } else {
            emaVideoBytesPerSecond = emaAlpha * current + (1.0 - emaAlpha) * emaVideoBytesPerSecond
        }
    }

    private func queueDurationSeconds(queueBytes: Int, fallbackBitRate: Int) -> Double {
        if emaVideoBytesPerSecond > 0 {
            // EMA 기반 비디오 전송 속도로 큐 지연 추정
            return Double(queueBytes) / emaVideoBytesPerSecond
        }
        // EMA 초기화 전에는 기존 비트레이트 기반 근사값 사용
        guard fallbackBitRate > 0 else { return .infinity }
        return Double(queueBytes * 8) / Double(fallbackBitRate)
    }

    private func dynamicReductionRatio(queueBytes: Int, fallbackBitRate: Int) -> Double {
        let duration = queueDurationSeconds(queueBytes: queueBytes, fallbackBitRate: fallbackBitRate)
        switch duration {
        case ..<0.1: return 0.10   // 100ms 미만: 가벼운 감소
        case ..<0.2: return 0.15   // 100~200ms: 기존 수준
        case ..<0.5: return 0.25   // 200~500ms: 중간 감소
        case ..<1.0: return 0.35   // 0.5~1s: 더 큰 감소
        case ..<2.0: return 0.50   // 1~2s: 크게 감소
        default:     return 0.70   // 2s 이상: 최대폭 감소
        }
    }

    /// 단계적 품질 저하 - 비트레이트 → 해상도 순서
    func degradeQuality(currentBitRate: Int, videoSettings: inout VideoCodecSettings) -> Bool {
        let needsUpdate = false

        // 1단계: 비트레이트가 이미 낮아진 상태인지 확인
        if !isBitRateDegraded {
            isBitRateDegraded = true
            degradationWaitCounts = 0
            print("[TABBER][1단계] 비트레이트 저하 시작")
        }

        // 대기 시간 증가
        degradationWaitCounts += 1
        
        // 2단계: 해상도 조절
//        if currentBitRate <= resolutionThresholdBitRate && !currentVideoSize.isLowest {
//            resolutionSetting(.down)
//            videoSettings.videoSize = currentVideoSize.size
//            needsUpdate = true
//            print("[TABBER][2단계] 해상도 조절: \(currentVideoSize.size)")
//        }

        return needsUpdate
    }

    /// 단계적 품질 복구 - 해상도 → 프레임레이트 → 비트레이트 순서 (저하의 역순)
    /// - Returns: (needsUpdate, recoveryType) - 업데이트 필요 여부와 복구 타입
    func recoverQuality(videoSettings: inout VideoCodecSettings) -> (needsUpdate: Bool, recoveryType: String) {
        // 1단계: 해상도 복구 (가장 먼저)
//        if !currentVideoSize.isHighest {
//            resolutionSetting(.up)
//            videoSettings.videoSize = currentVideoSize.size
//            return (true, "해상도")
//        }

        // 2단계: 프레임레이트 복구
        if !currentFrameRate.isHighest {
            frameRateSetting(.up)
            videoSettings.frameInterval = currentFrameRate.frameInterval
            return (true, "프레임레이트")
        }

        // 3단계: 비트레이트 복구 (이미 기존 로직에서 처리)
        // 모든 품질이 복구되면 저하 상태 리셋
        if currentVideoSize.isHighest {
            isBitRateDegraded = false
            degradationWaitCounts = 0
        }

        return (false, "")
    }

    /// 복구 허용 큐 duration 임계값 (이 값 이하일 때만 복구 진행)
    private let recoveryQueueDurationThreshold: Double = 0.5 // 0.5초
    /// 복구 허용 큐 바이트 임계값
    private let recoveryQueueBytesThreshold: Int = 100_000 // 100KB

    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            
            if initialVideoSize == nil {
                initialVideoSize = videoSettings.videoSize
            }

            // .status에서도 EMA 업데이트 (네트워크가 좋아질 때 EMA가 올라가도록)
            if report.currentBytesOutPerSecond > 0 {
                updateEmaVideoBytesPerSecond(
                    currentBytesOutPerSecond: report.currentBytesOutPerSecond,
                    audioBitRate: audioSettings.bitRate
                )
            }

            // 큐 상태 확인: 큐가 아직 많이 쌓여 있으면 복구하지 않음
            let currentBitRate = videoSettings.bitRate
            let queueDuration = queueDurationSeconds(queueBytes: report.currentQueueBytesOut, fallbackBitRate: currentBitRate)
            let queueTooLargeForRecovery = report.currentQueueBytesOut > recoveryQueueBytesThreshold || queueDuration > recoveryQueueDurationThreshold

            if queueTooLargeForRecovery {
                // 큐가 아직 많이 쌓여 있으면 안정 카운트 리셋하고 복구 중단
                stableCounts = 0

                // 큐가 이전보다 증가했는지 확인
                if report.currentQueueBytesOut > lastQueueBytesOut {
                    queueIncreasingCount += 1
                } else {
                    queueIncreasingCount = 0
                }
                lastQueueBytesOut = report.currentQueueBytesOut

                // 연속 2회 이상 큐가 증가하면 비트레이트를 추가 감산
                if queueIncreasingCount >= 2 {
                    let additionalReductionRatio = 0.10 // 10% 추가 감산
                    let newBitRate = Int(Double(videoSettings.bitRate) * (1.0 - additionalReductionRatio))
                    let clampedBitRate = max(newBitRate, minVideoBitRate)

                    effectiveMaxBitRate = clampedBitRate
                    videoSettings.bitRate = clampedBitRate

                    print("[TABBER][⏸️ 복구 보류 + 큐 증가 감지] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 연속 \(queueIncreasingCount)회 증가 → 비트레이트 10% 추가 감산: \(clampedBitRate)")

                    queueIncreasingCount = 0 // 감산 후 리셋
                    try? await stream.setVideoSettings(videoSettings)
                } else {
                    print("[TABBER][⏸️ 복구 보류] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 큐가 아직 많아서 복구 대기")
                }
                return
            }

            // 복구 진행 가능 상태이면 큐 증가 카운트 리셋
            queueIncreasingCount = 0
            lastQueueBytesOut = report.currentQueueBytesOut
            
            let maxRecoveryBitRate = Int(Double(effectiveMaxBitRate) * 0.9) // 상한의 90%
            
            if videoSettings.bitRate < maxRecoveryBitRate {
                // 아직 90% 미만이면: 비트레이트를 10%씩 복구
                stableCounts = 0  // 아직 완전 안정 상태는 아님
                
                let incremental = effectiveMaxBitRate / 10
                let temp = min(videoSettings.bitRate + incremental, maxRecoveryBitRate)
                videoSettings.bitRate = temp
                
                print("[TABBER][복구 🔄] 비트레이트 조정 ---------> \(temp) (상한의 90%: \(maxRecoveryBitRate)) | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")
                sufficientBWCounts = 0
                
                try? await stream.setVideoSettings(videoSettings)
            } else {
                // 이미 상한의 90% 근처에서 안정적으로 보내는 구간
                sufficientBWCounts = 0
                stableCounts += 1

                // N초 이상 안정 + 아직 최종 목표치보다 낮으면 상한 10% 올리기
                if stableCounts >= Self.stableCountsThreshold && effectiveMaxBitRate < mamimumVideoBitRate {
                    let newMax = min(Int(Double(effectiveMaxBitRate) * 1.1), mamimumVideoBitRate)
                    effectiveMaxBitRate = newMax
                    stableCounts = 0

                    print("[TABBER][📈 \(Self.stableCountsThreshold)초 안정 → 목표 상향] effectiveMaxBitRate ---------> \(effectiveMaxBitRate) | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")

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

                // 비디오 전용 전송 속도 EMA 업데이트
                updateEmaVideoBytesPerSecond(
                    currentBytesOutPerSecond: Int(report.currentBytesOutPerSecond),
                    audioBitRate: audioSettings.bitRate
                )
                
                let queueThreshold: Int = 300_000  // 300KB (임계값 조정 가능)
                let queueTooLarge = report.currentQueueBytesOut > queueThreshold
                let queueDuration = queueDurationSeconds(queueBytes: report.currentQueueBytesOut, fallbackBitRate: currentBitRate)
                
                if bandwidthRatio >= 0.8 && !queueTooLarge {
                    // 실제 대역폭 충분 + 큐도 적당함 → 무시
                    print("[TABBER][⚠️ 일시적 큐 증가] 실제 대역폭 충분 (\(Int(bandwidthRatio * 100))%), 큐 적정 → 조정 안함")
                    return
                }
                
                // 안정 상태 감지 임계값 (약 3초 이상 안정적이었을 때)
                let stableThresholdForGradualReduction: Int = 3
                let isStableState = stableCounts >= stableThresholdForGradualReduction
                
                // estimated가 현재 effectiveMaxBitRate보다 높으면 무시 (큐가 쌓여있는 상황에서 비트레이트가 올라가는 것 방지)
                let clampedEstimated = min(estimated, effectiveMaxBitRate)

                if isStableState {
                    // 안정 상태: 고정 15% 감소 (기존 로직)
                    let reductionRatio = 0.15
                    let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
                    let newMax = max(newBitRate, minVideoBitRate)
                    
                    // 감산된 값과 clampedEstimated 중 작은 값을 선택 (더 보수적으로)
                    effectiveMaxBitRate = min(newMax, clampedEstimated > 0 ? max(clampedEstimated, minVideoBitRate) : newMax)
                    let temp = Int(Double(effectiveMaxBitRate) * 0.9)
                    
                    if queueTooLarge {
                        print("[TABBER][⚠️ 안정 상태 → 점진적 감소] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                    } else {
                        print("[TABBER][⚠️ 안정 상태 → 점진적 감소] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                    }
                    
                    // 안정 상태에서는 stableCounts를 완전히 리셋하지 않고 감소시킴
                    stableCounts = max(0, stableCounts - 10)
                } else {
                    // 비안정 상태: 큐 duration 기반 동적 감소
                    let reductionRatio = dynamicReductionRatio(queueBytes: report.currentQueueBytesOut, fallbackBitRate: currentBitRate)
                    let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
                    
                    // 감산된 값과 clampedEstimated 중 작은 값을 선택 (더 보수적으로)
                    let candidate = max(newBitRate, minVideoBitRate)
                    effectiveMaxBitRate = min(candidate, clampedEstimated > 0 ? max(clampedEstimated, minVideoBitRate) : candidate)
                    let temp = Int(Double(effectiveMaxBitRate) * 0.9)
                    
                    if queueTooLarge {
                        print("[TABBER][❌ 큐 과다!!] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                    } else {
                        print("[TABBER][❌ 대역폭 부족!!] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp) | effectiveMaxBitRate: \(effectiveMaxBitRate)")
                    }
                    
                    // 비안정 상태에서는 stableCounts를 완전히 리셋
                    stableCounts = 0
                }
                
                videoSettings.bitRate = Int(Double(effectiveMaxBitRate) * 0.9)

                // 단계적 품질 저하 적용 (비트레이트 → 해상도)
                _ = degradeQuality(currentBitRate: videoSettings.bitRate, videoSettings: &videoSettings)

                sufficientBWCounts = 0
                zeroBytesOutPerSecondCounts = 0
                try? await stream.setVideoSettings(videoSettings)
            }
        case .reset:
            var videoSettings = await stream.videoSettings
            zeroBytesOutPerSecondCounts = 0
            emaVideoBytesPerSecond = 0
            lastQueueBytesOut = 0
            queueIncreasingCount = 0
            effectiveMaxBitRate = mamimumVideoBitRate
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
