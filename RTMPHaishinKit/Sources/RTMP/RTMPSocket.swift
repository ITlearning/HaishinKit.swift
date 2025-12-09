import Foundation
import HaishinKit
import Network

final actor RTMPSocket {
    static let defaultWindowSizeC = Int(UInt8.max)

    enum Error: Swift.Error {
        case invalidState
        case endOfStream
        case connectionTimedOut
        case connectionNotEstablished(_ error: NWError?)
    }

    private var timeout: UInt64 = 15
    private var connected = false
    private var windowSizeC = RTMPSocket.defaultWindowSizeC
    private var securityLevel: StreamSocketSecurityLevel = .none
    private var totalBytesIn = 0
    private var queueBytesOut = 0
    private var totalBytesOut = 0
    private var isSkipping = false
    private var skipModeInitialQueueSize = 0
    private var parameters: NWParameters = .tcp
    private var connection: NWConnection? {
        didSet {
            oldValue?.viabilityUpdateHandler = nil
            oldValue?.stateUpdateHandler = nil
            oldValue?.forceCancel()
        }
    }
    private var outputs: AsyncStream<Data>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var qualityOfService: DispatchQoS = .userInitiated
    private var continuation: CheckedContinuation<Void, any Swift.Error>?
    private lazy var networkQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.RTMPSocket.network", qos: qualityOfService)

    init() {
    }

    init(qualityOfService: DispatchQoS, securityLevel: StreamSocketSecurityLevel) {
        self.qualityOfService = qualityOfService
        switch securityLevel {
        case .ssLv2, .ssLv3, .tlSv1, .negotiatedSSL:
            parameters = .tls
        default:
            parameters = .tcp
        }
    }

    func connect(_ name: String, port: Int) async throws {
        guard !connected else {
            throw Error.invalidState
        }
        totalBytesIn = 0
        totalBytesOut = 0
        queueBytesOut = 0
        do {
            let connection = NWConnection(to: NWEndpoint.hostPort(host: .init(name), port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))), using: parameters)
            self.connection = connection
            try await withCheckedThrowingContinuation { (checkedContinuation: CheckedContinuation<Void, Swift.Error>) in
                self.continuation = checkedContinuation
                Task {
                    try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    guard let continuation else {
                        return
                    }
                    continuation.resume(throwing: Error.connectionTimedOut)
                    self.continuation = nil
                    close()
                }
                connection.stateUpdateHandler = { state in
                    Task { await self.stateDidChange(to: state) }
                }
                connection.viabilityUpdateHandler = { viability in
                    Task { await self.viabilityDidChange(to: viability) }
                }
                connection.start(queue: networkQueue)
            }
        } catch {
            throw error
        }
    }

    func send(_ data: Data) {
        guard connected else {
            return
        }
        // In skipping mode, drop all new frames to drain the buffer
        if isSkipping {
            return
        }
        queueBytesOut += data.count
        outputs?.yield(data)
    }

    func send(_ iterator: AnyIterator<Data>) {
        guard connected else {
            return
        }
        for data in iterator {
            // In skipping mode, drop all new frames to drain the buffer
            if isSkipping {
                continue
            }
            queueBytesOut += data.count
            outputs?.yield(data)
        }
    }

    func recv() -> AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            Task {
                do {
                    while connected {
                        let data = try await recv()
                        continuation.yield(data)
                        totalBytesIn += data.count
                    }
                } catch {
                    continuation.finish()
                }
            }
        }
    }

    func close(_ error: NWError? = nil) {
        guard connection != nil else {
            return
        }
        if let continuation {
            continuation.resume(throwing: Error.connectionNotEstablished(error))
            self.continuation = nil
        }
        connected = false
        outputs = nil
        connection = nil
        continuation = nil
    }

    /// Starts skipping mode to quickly drain the buffer.
    func startSkipping() {
        guard !isSkipping else {
            return // Already in skip mode, don't restart
        }
        isSkipping = true
        skipModeInitialQueueSize = queueBytesOut
        let queueMB = String(format: "%.2f", Double(queueBytesOut) / 1024 / 1024)
        logger.info("[NetworkMonitor] Started buffer skipping mode. Current queue: \(queueMB)MB (\(queueBytesOut) bytes)")
        
        // Auto-stop skip mode after 2 seconds to prevent complete drain
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            if isSkipping {
                logger.info("[NetworkMonitor] Auto-stopping skip mode after 2 seconds to prevent disconnect")
                stopSkipping()
            }
        }
    }

    /// Stops skipping mode and returns to normal operation.
    func stopSkipping() {
        guard isSkipping else {
            return // Not in skip mode
        }
        isSkipping = false
        let queueMB = String(format: "%.2f", Double(queueBytesOut) / 1024 / 1024)
        logger.info("[NetworkMonitor] Stopped buffer skipping mode. Final queue: \(queueMB)MB (\(queueBytesOut) bytes)")
    }

    /// Checks if the data contains a key frame (I-frame).
    private func isKeyFrame(_ data: Data) -> Bool {
        // RTMP video message: first byte contains frame type in upper 4 bits
        // Frame type 1 = keyframe (I-frame)
        guard data.count > 0 else { return false }
        let frameType = (data[0] >> 4) & 0x0F
        return frameType == 1  // RTMPFrameType.key.rawValue
    }

    private func stateDidChange(to state: NWConnection.State) {
        switch state {
        case .ready:
            logger.info("Connection is ready.")
            connected = true
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            Task {
                for await data in stream where connected {
                    // In skip mode, check if buffer is low enough to stop
                    if isSkipping {
                        // Stop skip mode when buffer is reduced to 1MB
                        if queueBytesOut <= 1024 * 1024 {
                            let queueMB = String(format: "%.2f", Double(queueBytesOut) / 1024 / 1024)
                            logger.info("[NetworkMonitor] Buffer at \(queueMB)MB, stopping skip mode")
                            stopSkipping()
                        }
                    }
                    
                    try await send(data)
                    totalBytesOut += data.count
                    queueBytesOut -= data.count
                }
            }
            self.outputs = continuation
            self.continuation?.resume()
            self.continuation = nil
        case .waiting(let error):
            logger.warn("Connection waiting:", error)
            close(error)
        case .setup:
            logger.debug("Connection is setting up.")
        case .preparing:
            logger.debug("Connection is preparing.")
        case .failed(let error):
            logger.warn("Connection failed:", error)
            close(error)
        case .cancelled:
            logger.info("Connection cancelled.")
            close()
        @unknown default:
            logger.error("Unknown connection state.")
        }
    }

    private func viabilityDidChange(to viability: Bool) {
        logger.info("Connection viability changed to ", viability)
        if viability == false {
            close()
        }
    }

    private func send(_ data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }
    }

    private func recv() async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.receive(minimumIncompleteLength: 0, maximumLength: windowSizeC) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: Error.endOfStream)
                }
            }
        }
    }
}

extension RTMPSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkMonitor() async -> NetworkMonitor {
        return .init(self)
    }

    func makeNetworkTransportReport() -> NetworkTransportReport {
        return .init(queueBytesOut: queueBytesOut, totalBytesIn: totalBytesIn, totalBytesOut: totalBytesOut)
    }
}
