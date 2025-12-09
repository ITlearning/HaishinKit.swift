import Foundation

/// An enumeration that indicate the network monitor event.
public enum NetworkMonitorEvent: Sendable {
    /// To update statistics.
    case status(report: NetworkMonitorReport)
    /// To publish sufficient bandwidth occured.
    case publishInsufficientBWOccured(report: NetworkMonitorReport)
    /// Buffer delay exceeded threshold.
    case bufferDelayExceeded(report: NetworkMonitorReport, estimatedDelay: TimeInterval)
    /// Buffer delay reached target during skip mode.
    case bufferDelayTargetReached(report: NetworkMonitorReport, estimatedDelay: TimeInterval)
    /// To reset  statistics.
    case reset
}
