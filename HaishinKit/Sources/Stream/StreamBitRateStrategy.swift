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

    /// 안정 카운트 임계값 (고정)
    private let stableCountsThreshold: Int = 30

    private var stableCounts: Int = 0
    
    public let mamimumVideoBitRate: Int
    public var effectiveMaxBitRate: Int
    /// 최소 비트레이트: 최대의 25% (Larix 스타일)
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

    // Larix 스타일 복구 단위: 500Kbps 고정
    private let recoveryIncrementBitRate: Int = 500_000 // 500Kbps

    private var initialVideoSize: CGSize?
    private var currentVideoSize: Resolution = .p1080

    /// 비트레이트 저하 후 경과 시간 추적
    private var degradationWaitCounts: Int = 0
    /// 비트레이트만 조절한 상태인지 추적
    private var isBitRateDegraded: Bool = false

    /// Creates a new instance.
    /// - Parameters:
    ///   - mamimumVideoBitrate: 최대 비디오 비트레이트
    ///   - resolutionThresholdBitRate: 해상도 조절 임계 비트레이트 (기본 1,000,000 = 1000kbps)
    public init(mamimumVideoBitrate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitrate
        self.effectiveMaxBitRate = mamimumVideoBitrate
        // Larix 스타일: 최소 비트레이트는 최대의 25%
        self.minVideoBitRate = max(mamimumVideoBitrate / 8, 500000)
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
        print("[SL LOG] 📺 해상도 \(control == .up ? "UP" : "DOWN" ) : 기존 \(temp.size) --> 변경 \(currentVideoSize.size)")
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

    /// 비트레이트 저하 상태 기록
    /// - Returns: 항상 false (비트레이트만 조절, 해상도/프레임레이트는 조절하지 않음)
    func degradeQuality(currentBitRate: Int, queueDuration: Double, videoSettings: inout VideoCodecSettings) -> Bool {
        // 비트레이트가 이미 낮아진 상태인지 확인
        if !isBitRateDegraded {
            isBitRateDegraded = true
            degradationWaitCounts = 0
            print("[SL LOG] 비트레이트 저하 시작")
        }

        // 대기 시간 증가
        degradationWaitCounts += 1

        // 해상도/프레임레이트는 조절하지 않음 - 비트레이트만 조절
        return false
    }

    /// 품질 복구 상태 리셋
    /// - Returns: 항상 (false, "") - 비트레이트 복구는 기존 로직에서 처리
    func recoverQuality(videoSettings: inout VideoCodecSettings) -> (needsUpdate: Bool, recoveryType: String) {
        // 비트레이트 복구는 기존 로직에서 처리
        // 저하 상태 리셋
        isBitRateDegraded = false
        degradationWaitCounts = 0

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
                if queueIncreasingCount >= 1 {
                    let additionalReductionRatio = 0.15 // 15% 추가 감산
                    let newBitRate = Int(Double(videoSettings.bitRate) * (1.0 - additionalReductionRatio))
                    let clampedBitRate = max(newBitRate, minVideoBitRate)

                    effectiveMaxBitRate = clampedBitRate
                    videoSettings.bitRate = clampedBitRate

                    print("[SL LOG][⏸️ 복구 보류 + 큐 증가 감지] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 연속 \(queueIncreasingCount)회 증가 → 비트레이트 10% 추가 감산: \(clampedBitRate)")

                    queueIncreasingCount = 0 // 감산 후 리셋
                    try? await stream.setVideoSettings(videoSettings)
                } else {
                    print("[SL LOG][⏸️ 복구 보류] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 큐가 아직 많아서 복구 대기")
                }
                return
            }

            // 복구 진행 가능 상태이면 큐 증가 카운트 리셋
            queueIncreasingCount = 0
            lastQueueBytesOut = report.currentQueueBytesOut
            
            let maxRecoveryBitRate = Int(Double(effectiveMaxBitRate) * 0.9) // 상한의 90%
            
            if videoSettings.bitRate < maxRecoveryBitRate {
                // 아직 90% 미만이면: Larix 스타일 500Kbps 단위로 복구
                stableCounts = 0  // 아직 완전 안정 상태는 아님
                
                // Larix 스타일: 500Kbps 고정 단위로 복구
                let temp = min(videoSettings.bitRate + recoveryIncrementBitRate, maxRecoveryBitRate)
                videoSettings.bitRate = temp
                
                print("[SL LOG][복구 🔄] 비트레이트 +500Kbps ---------> \(temp / 1000)Kbps (상한의 90%: \(maxRecoveryBitRate / 1000)Kbps) | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")
                sufficientBWCounts = 0
                
                try? await stream.setVideoSettings(videoSettings)
            } else {
                // 이미 상한의 90% 근처에서 안정적으로 보내는 구간
                sufficientBWCounts = 0
                stableCounts += 1

                // N초 이상 안정 + 아직 최종 목표치보다 낮으면 상한 올리기 (Larix 스타일: 500Kbps 단위)
                if stableCounts >= stableCountsThreshold && effectiveMaxBitRate < mamimumVideoBitRate {
                    // Larix 스타일: 500Kbps 단위로 상한 올리기
                    let newMax = min(effectiveMaxBitRate + recoveryIncrementBitRate, mamimumVideoBitRate)
                    effectiveMaxBitRate = newMax
                    stableCounts = 0

                    print("[SL LOG][📈 \(stableCountsThreshold)초 안정 → 목표 +500Kbps] effectiveMaxBitRate ---------> \(effectiveMaxBitRate / 1000)Kbps | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")

                    // 단계적 품질 복구 (해상도)
                    let (needsUpdate, recoveryType) = recoverQuality(videoSettings: &videoSettings)
                    if needsUpdate {
                        print("[SL LOG][복구 🔄] \(recoveryType) 복구 완료")
                        do {
                            try await stream.setVideoSettings(videoSettings)
                        } catch {
                            print("[SL LOG] \(recoveryType) 복구 적용 실패 \(error.localizedDescription)")
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
                    print("[SL LOG][⚠️ 일시적 큐 증가] 실제 대역폭 충분 (\(Int(bandwidthRatio * 100))%), 큐 적정 → 조정 안함")
                    return
                }
                
                // 안정 상태 감지 임계값 (약 3초 이상 안정적이었을 때)
                let stableThresholdForGradualReduction: Int = 3
                let isStableState = stableCounts >= stableThresholdForGradualReduction
                
                if isStableState {
                    // 안정 상태: 고정 15% 감소
                    let reductionRatio = 0.15
                    let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
                    effectiveMaxBitRate = max(newBitRate, minVideoBitRate)
                    let temp = Int(Double(effectiveMaxBitRate) * 0.9)
                    
                    if queueTooLarge {
                        print("[SL LOG][⚠️ 안정 상태 → 점진적 감소] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
                    } else {
                        print("[SL LOG][⚠️ 안정 상태 → 점진적 감소] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
                    }
                    
                    // 안정 상태에서는 stableCounts를 완전히 리셋하지 않고 감소시킴
                    stableCounts = max(0, stableCounts - 10)

                } else {
                    // 비안정 상태: 큐 duration 기반 동적 감소 (순수 감산율만 적용)
                    let reductionRatio = dynamicReductionRatio(queueBytes: report.currentQueueBytesOut, fallbackBitRate: currentBitRate)
                    let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
                    effectiveMaxBitRate = max(newBitRate, minVideoBitRate)
                    let temp = Int(Double(effectiveMaxBitRate) * 0.9)
                    
                    if queueTooLarge {
                        print("[SL LOG][❌ 큐 과다!!] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
                    } else {
                        print("[SL LOG][❌ 대역폭 부족!!] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(temp / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
                    }
                    
                    // 비안정 상태에서는 stableCounts를 완전히 리셋
                    stableCounts = 0

                }
                
                videoSettings.bitRate = Int(Double(effectiveMaxBitRate) * 0.9)

                // 단계적 품질 저하 적용 (비트레이트 → 프레임레이트 → 해상도)
                _ = degradeQuality(currentBitRate: videoSettings.bitRate, queueDuration: queueDuration, videoSettings: &videoSettings)

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
