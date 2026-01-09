import Foundation

/// A type with a network bitrate strategy representation.
public protocol StreamBitRateStrategy: Sendable {
    /// The maximum video bitRate.
    var mamimumVideoBitRate: Int { get }
    /// The maximum audio bitRate.
    var mamimumAudioBitRate: Int { get }

    /// Adjust a bitRate.
    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async
}

/// An actor provides an algorithm that focuses on video bitrate control.
public final actor StreamVideoAdaptiveBitRateStrategy: StreamBitRateStrategy {
    /// The status counts threshold for restoring the status
    public static let statusCountsThreshold: Int = 15

    /// 장기 안정 카운트 임계값 (30초 안정 상태 유지 시 상한 증가)
    private let longTermStableCountsThreshold: Int = 30

    /// 비트레이트 감소율
    private let stableStateReductionRatio: Double = 0.15  // 안정 상태: 15% 감소
    private let additionalReductionRatio: Double = 0.15   // 큐 증가 감지 시 추가 감산: 15%
    private var stableCounts: Int = 0

    private var sufficientBandwidthCounts: Int = 0
    private var zeroBytesOutPerSecondCounts: Int = 0

    // 비디오 전용 전송 속도 EMA (bytes/sec)
    private var emaVideoBytesPerSecond: Double = 0
    private let emaAlpha: Double = 0.2

    // 복구 보류 중 큐 증가 감지용
    private var lastQueueBytesOut: Int = 0
    private var queueIncreasingCount: Int = 0 // 연속으로 큐가 증가한 횟수

    // Larix 스타일 복구 단위: 500Kbps 고정
    private let recoveryIncrementBitRate: Int = 500_000 // 500Kbps

    /// 복구 허용 큐 duration 임계값 (이 값 이하일 때만 복구 진행)
    private let recoveryAllowedQueueDurationThreshold: Double = 1.0 // 1초
    /// 복구 허용 큐 바이트 임계값 (이 값 이하일 때만 복구 진행)
    private let recoveryAllowedQueueBytesThreshold: Int = 200_000 // 200KB

    /// 대역폭 부족 감지 시 큐 과다 판정 임계값 (복구 허용 임계값보다 높음)
    private let congestionQueueBytesThreshold: Int = 300_000  // 300KB

    /// 단기 안정 상태 감지 임계값 (3초 이상 안정적이면 점진적 감소 적용)
    private let shortTermStableCountsThreshold: Int = 3

    /// effectiveMaxBitRate의 90%를 계산 (복구 목표 비트레이트)
    private func calculateRecoveryTargetBitRate() -> Int {
        return Int(Double(effectiveMaxBitRate) * 0.9)
    }
    
    // MARK: public property
    public let mamimumVideoBitRate: Int
    public var effectiveMaxBitRate: Int
    /// 최소 비트레이트: 최대의 15%
    public let minVideoBitRate: Int
    public let mamimumAudioBitRate: Int = 0
    
    /// Creates a new instance.
    /// - Parameters:
    ///   - maximumVideoBitrate: 최대 비디오 비트레이트
    public init(mamimumVideoBitRate: Int) {
        self.mamimumVideoBitRate = mamimumVideoBitRate
        self.effectiveMaxBitRate = mamimumVideoBitRate
        // 최소 비트레이트는 최대의 15%, 단 500kbps 이상 보장
        self.minVideoBitRate = max(Int(Double(mamimumVideoBitRate) * 0.15), 500_000)
    }
    
    public func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
        switch event {
        case .status(let report):
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings

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
            let queueTooLargeForRecovery = report.currentQueueBytesOut > recoveryAllowedQueueBytesThreshold || queueDuration > recoveryAllowedQueueDurationThreshold

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

                // 연속 2회 이상 큐가 증가하면 비트레이트를 15% 감소 (단, 최소 500Kbps 보장)
                if queueIncreasingCount >= 1 {
                    let newBitRate = Int(Double(videoSettings.bitRate) * (1.0 - additionalReductionRatio))
                    let clampedBitRate = max(newBitRate, 500_000) // 최소 500Kbps

                    effectiveMaxBitRate = clampedBitRate
                    videoSettings.bitRate = clampedBitRate

                    print("[SL LOG][⏸️ 복구 보류 + 큐 증가 감지] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 연속 \(queueIncreasingCount)회 증가 → 비트레이트 \(additionalReductionRatio)% 감산: \(clampedBitRate / 1000)Kbps")

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

            let maxRecoveryBitRate = calculateRecoveryTargetBitRate() // 상한의 90%

            if videoSettings.bitRate < maxRecoveryBitRate {
                // 아직 90% 미만이면: Larix 스타일 500Kbps 단위로 복구
                stableCounts = 0  // 아직 완전 안정 상태는 아님
                
                // Larix 스타일: 500Kbps 고정 단위로 복구
                let temp = min(videoSettings.bitRate + recoveryIncrementBitRate, maxRecoveryBitRate)
                videoSettings.bitRate = temp
                
                print("[SL LOG][복구 🔄] 비트레이트 +500Kbps ---------> \(temp / 1000)Kbps (상한의 90%: \(maxRecoveryBitRate / 1000)Kbps) | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")
                sufficientBandwidthCounts = 0
                
                try? await stream.setVideoSettings(videoSettings)
            } else {
                // 이미 상한의 90% 근처에서 안정적으로 보내는 구간
                sufficientBandwidthCounts = 0
                stableCounts += 1

                // 30초 이상 안정 + 아직 최종 목표치보다 낮으면 상한 올리기 (Larix 스타일: 500Kbps 단위)
                if stableCounts >= longTermStableCountsThreshold && effectiveMaxBitRate < mamimumVideoBitRate {
                    // Larix 스타일: 500Kbps 단위로 상한 올리기
                    let newMax = min(effectiveMaxBitRate + recoveryIncrementBitRate, mamimumVideoBitRate)
                    effectiveMaxBitRate = newMax
                    stableCounts = 0

                    print("[SL LOG][📈 \(longTermStableCountsThreshold)초 안정 → 목표 +500Kbps] effectiveMaxBitRate ---------> \(effectiveMaxBitRate / 1000)Kbps | 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s)")
                }
            }
        case .publishInsufficientBWOccured(let report):
            sufficientBandwidthCounts = 0
            var videoSettings = await stream.videoSettings
            let audioSettings = await stream.audioSettings
            let currentBitRate = videoSettings.bitRate

            let queueDuration = queueDurationSeconds(
                queueBytes: report.currentQueueBytesOut,
                fallbackBitRate: currentBitRate
            )

            // currentBytesOutPerSecond가 0이면 (네트워크가 막힌 상태)
            if report.currentBytesOutPerSecond == 0 {
                // 큐가 쌓이고 있으면 비트레이트를 강제로 감소
                if report.currentQueueBytesOut > congestionQueueBytesThreshold {
                    let reductionRatio = dynamicReductionRatio(queueBytes: report.currentQueueBytesOut, fallbackBitRate: currentBitRate)
                    let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
                    effectiveMaxBitRate = max(newBitRate, minVideoBitRate)
                    videoSettings.bitRate = calculateRecoveryTargetBitRate()

                    print("[SL LOG][🚫 전송 중단 + 큐 과다] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 강제 감소: \(videoSettings.bitRate / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")

                    stableCounts = 0
                    sufficientBandwidthCounts = 0
                    zeroBytesOutPerSecondCounts = 0
                    try? await stream.setVideoSettings(videoSettings)
                } else {
                    print("[SL LOG][🚫 전송 중단] 큐: \(report.currentQueueBytesOut / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 대기 중")
                }
                return
            }

            // 대역폭 비율 계산
            let bandwidthRatio = calculateBandwidthRatio(
                currentBytesOutPerSecond: report.currentBytesOutPerSecond,
                currentBitRate: currentBitRate
            )

            // 비디오 전용 전송 속도 EMA 업데이트
            updateEmaVideoBytesPerSecond(
                currentBytesOutPerSecond: report.currentBytesOutPerSecond,
                audioBitRate: audioSettings.bitRate
            )

            // 일시적 큐 증가인지 확인
            if isTemporaryQueueIncrease(bandwidthRatio: bandwidthRatio, queueBytes: report.currentQueueBytesOut) {
                print("[SL LOG][⚠️ 일시적 큐 증가] 실제 대역폭 충분 (\(Int(bandwidthRatio * 100))%), 큐 적정 → 조정 안함")
                return
            }

            // 안정 상태 판단
            let isStableState = stableCounts >= shortTermStableCountsThreshold

            // 비트레이트 감소 적용
            applyBitrateReduction(
                currentBitRate: currentBitRate,
                queueBytes: report.currentQueueBytesOut,
                queueDuration: queueDuration,
                isStable: isStableState,
                bandwidthRatio: bandwidthRatio
            )

            videoSettings.bitRate = calculateRecoveryTargetBitRate()

            sufficientBandwidthCounts = 0
            zeroBytesOutPerSecondCounts = 0
            try? await stream.setVideoSettings(videoSettings)
        case .reset:
            var videoSettings = await stream.videoSettings
            zeroBytesOutPerSecondCounts = 0
            emaVideoBytesPerSecond = 0
            lastQueueBytesOut = 0
            queueIncreasingCount = 0
            effectiveMaxBitRate = mamimumVideoBitRate
            videoSettings.bitRate = mamimumVideoBitRate
            // 상태 초기화
            stableCounts = 0
            try? await stream.setVideoSettings(videoSettings)
        }
    }
}

extension StreamVideoAdaptiveBitRateStrategy {
    
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

    /// 대역폭 비율 계산
    private func calculateBandwidthRatio(currentBytesOutPerSecond: Int, currentBitRate: Int) -> Double {
        let currentBandwidth = currentBytesOutPerSecond * 8
        return Double(currentBandwidth) / Double(currentBitRate)
    }

    /// 일시적 큐 증가인지 판단 (대역폭 충분하고 큐도 적당함)
    private func isTemporaryQueueIncrease(bandwidthRatio: Double, queueBytes: Int) -> Bool {
        return bandwidthRatio >= 0.8 && queueBytes <= congestionQueueBytesThreshold
    }
    
    /// 비트레이트 감소 적용 (안정/비안정 상태에 따라)
    private func applyBitrateReduction(
        currentBitRate: Int,
        queueBytes: Int,
        queueDuration: Double,
        isStable: Bool,
        bandwidthRatio: Double
    ) {
        let queueTooLarge = queueBytes > congestionQueueBytesThreshold

        if isStable {
            // 안정 상태: 고정 15% 감소
            let newBitRate = Int(Double(currentBitRate) * (1.0 - stableStateReductionRatio))
            effectiveMaxBitRate = max(newBitRate, minVideoBitRate)
            let targetBitRate = calculateRecoveryTargetBitRate()

            if queueTooLarge {
                print("[SL LOG][⚠️ 안정 상태 → 점진적 감소] 큐: \(queueBytes / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(stableStateReductionRatio * 100))% → 비트레이트 조정: \(targetBitRate / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
            } else {
                print("[SL LOG][⚠️ 안정 상태 → 점진적 감소] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(stableStateReductionRatio * 100))% → 비트레이트 조정: \(targetBitRate / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
            }

            // 안정 상태에서는 stableCounts를 완전히 리셋 (비트레이트 감소 발생 시)
            stableCounts = 0

        } else {
            // 비안정 상태: 큐 duration 기반 동적 감소
            let reductionRatio = dynamicReductionRatio(queueBytes: queueBytes, fallbackBitRate: currentBitRate)
            let newBitRate = Int(Double(currentBitRate) * (1.0 - reductionRatio))
            effectiveMaxBitRate = max(newBitRate, minVideoBitRate)
            let targetBitRate = calculateRecoveryTargetBitRate()

            if queueTooLarge {
                print("[SL LOG][❌ 큐 과다!!] 큐: \(queueBytes / 1024)KB (\(String(format: "%.2f", queueDuration))s) → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(targetBitRate / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
            } else {
                print("[SL LOG][❌ 대역폭 부족!!] 실제 대역폭: \(Int(bandwidthRatio * 100))% / 큐: \(String(format: "%.2f", queueDuration))s → 감산율: \(Int(reductionRatio * 100))% → 비트레이트 조정: \(targetBitRate / 1000)Kbps | effectiveMaxBitRate: \(effectiveMaxBitRate / 1000)Kbps")
            }

            // 비안정 상태에서는 stableCounts를 완전히 리셋
            stableCounts = 0
        }
    }

}
