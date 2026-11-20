import Foundation

public enum LiveActivityThrottle {
  public static func shouldUpdate(elapsed: Duration, stateChanged: Bool) -> Bool {
    elapsed >= .seconds(30) || (stateChanged && elapsed >= .seconds(1))
  }
}

public enum BackupActivityOutcome: String, Codable, Sendable {
  case complete
  case incomplete
  case stopped

  public init(completed: Int, total: Int, stopped: Bool) {
    self = if stopped { .stopped } else if total > 0 && completed >= total { .complete } else { .incomplete }
  }
}

#if os(iOS) && canImport(ActivityKit)
  import ActivityKit

  public struct BackupActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
      public enum Phase: String, Codable, Sendable {
        case uploading
        case paused
        case waitingForNetwork
        case offline
        case finishing
        case waitingForGoogle
        case ended
      }

      public var progress: Double {
        if let outcome {
          return outcome == .complete ? 1 : (totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0)
        }
        if bytesTotal > 0 {
          return min(0.99, max(0, Double(bytesSent) / Double(bytesTotal)))
        }
        return totalCount > 0 ? min(1, max(0, Double(completedCount) / Double(totalCount))) : 0
      }

      public var outcome: BackupActivityOutcome?
      public var phase: Phase
      public var completedCount: Int
      public var totalCount: Int
      public var bytesSent: Int64
      public var bytesTotal: Int64
      public var etaText: String
      public var currentFilename: String?

      public init(
        phase: Phase,
        completedCount: Int,
        totalCount: Int,
        bytesSent: Int64,
        bytesTotal: Int64,
        etaText: String,
        currentFilename: String? = nil,
        outcome: BackupActivityOutcome? = nil
      ) {
        self.outcome = outcome
        self.phase = phase
        self.completedCount = completedCount
        self.totalCount = totalCount
        self.bytesSent = bytesSent
        self.bytesTotal = bytesTotal
        self.etaText = etaText
        self.currentFilename = currentFilename
      }
    }

    public var title: String

    public init(title: String = "Google Photos") {
      self.title = title
    }
  }
#endif
