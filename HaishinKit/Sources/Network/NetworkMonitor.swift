import Foundation

/// An objec thatt provides the RTMPConnection, SRTConnection's monitoring events.
package final actor NetworkMonitor {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
    }

    /// An asynchronous sequence for network monitoring  event.
    public var event: AsyncStream<NetworkMonitorEvent> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public private(set) var isRunning = false
    private var timer: Task<Void, Never>? {
        didSet {
            oldValue?.cancel()
        }
    }
    private var measureInterval = 3
    private var currentBytesInPerSecond = 0
    private var currentBytesOutPerSecond = 0
    private var previousTotalBytesIn = 0
    private var previousTotalBytesOut = 0
    private var previousQueueBytesOut: [Int] = []
    private var recentBytesOutPerSecond: [Int] = []  // Track recent throughput for averaging
    package private(set) var bufferDelayThreshold: TimeInterval
    private var continuation: AsyncStream<NetworkMonitorEvent>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private weak var reporter: (any NetworkTransportReporter)?

    /// Creates a new instance.
    package init(_ reporter: some NetworkTransportReporter, bufferDelayThreshold: TimeInterval = 60.0) {
        self.reporter = reporter
        self.bufferDelayThreshold = bufferDelayThreshold
    }

    /// Sets the buffer delay threshold for triggering buffer flush.
    package func setBufferDelayThreshold(_ threshold: TimeInterval) {
        self.bufferDelayThreshold = threshold
    }

    private func collect() async throws -> NetworkMonitorEvent {
        guard let report = await reporter?.makeNetworkTransportReport() else {
            throw Error.invalidState
        }
        let totalBytesIn = report.totalBytesIn
        let totalBytesOut = report.totalBytesOut
        let queueBytesOut = report.queueBytesOut
        currentBytesInPerSecond = totalBytesIn - previousTotalBytesIn
        currentBytesOutPerSecond = totalBytesOut - previousTotalBytesOut
        previousTotalBytesIn = totalBytesIn
        previousTotalBytesOut = totalBytesOut
        previousQueueBytesOut.append(queueBytesOut)
        
        // Track recent throughput for calculating average
        recentBytesOutPerSecond.append(currentBytesOutPerSecond)
        if recentBytesOutPerSecond.count > 5 {  // Keep last 5 seconds
            recentBytesOutPerSecond.removeFirst()
        }
        
        let eventReport = NetworkMonitorReport(
            totalBytesIn: totalBytesIn,
            totalBytesOut: totalBytesOut,
            currentQueueBytesOut: queueBytesOut,
            currentBytesInPerSecond: currentBytesInPerSecond,
            currentBytesOutPerSecond: currentBytesOutPerSecond
        )
        // Calculate estimated delay based on queue size and average output rate
        // Use moving average of last 5 seconds to smooth out temporary fluctuations
        let estimatedDelay: TimeInterval
        if !recentBytesOutPerSecond.isEmpty {
            let avgBytesOutPerSecond = recentBytesOutPerSecond.reduce(0, +) / recentBytesOutPerSecond.count
            if avgBytesOutPerSecond > 0 {
                estimatedDelay = TimeInterval(queueBytesOut) / TimeInterval(avgBytesOutPerSecond)
            } else {
                estimatedDelay = 0
            }
        } else {
            estimatedDelay = 0
        }
        // Check if buffer delay exceeds threshold
        if estimatedDelay > bufferDelayThreshold {
            return .bufferDelayExceeded(report: eventReport, estimatedDelay: estimatedDelay)
        }
        if measureInterval <= previousQueueBytesOut.count {
            defer {
                previousQueueBytesOut.removeFirst()
            }
            var total = 0
            for i in 0..<previousQueueBytesOut.count - 1 where previousQueueBytesOut[i] < previousQueueBytesOut[i + 1] {
                total += 1
            }
            if total == measureInterval - 1 {
                return .publishInsufficientBWOccured(report: eventReport)
            } else if total == 0 {
                return .status(report: eventReport)
            }
        }
        return .status(report: eventReport)
    }
}

extension NetworkMonitor: AsyncRunner {
    // MARK: AsyncRunner
    package func startRunning() {
        guard !isRunning else {
            return
        }
        isRunning = true
        timer = Task {
            let timer = AsyncStream {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            for await _ in timer {
                do {
                    let event = try await collect()
                    continuation?.yield(event)
                } catch {
                    continuation?.finish()
                }
            }
        }
    }

    package func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        timer = nil
        continuation = nil
    }
}
