import Foundation

/// The background URLSession the photo upload extension sends files with. iOS finishes each
/// transfer after the extension (and the app) are gone, then hands the session's events to
/// whichever of them holds the session, which writes the outcome to the ledger.
public enum BackgroundUploadTransfers {
  public static let sessionPrefix = "org.gphotosapp.gphotos.background-upload."

  /// Only one process may hold a background session at a time, and the app connects to one
  /// when iOS wakes it for its events, so each extension instance makes its own.
  public static func newSessionID() -> String {
    sessionPrefix + UUID().uuidString
  }

  public static func session(id: String, delegate: Delegate, meteredAllowed: Bool) -> URLSession {
    let configuration = URLSessionConfiguration.background(withIdentifier: id)
    configuration.sharedContainerIdentifier = AppGroupConstants.identifier
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.allowsCellularAccess = meteredAllowed
    configuration.allowsExpensiveNetworkAccess = meteredAllowed
    configuration.allowsConstrainedNetworkAccess = true
    configuration.timeoutIntervalForRequest = 300
    configuration.timeoutIntervalForResource = BackgroundUploadJob.abandonAfter
    configuration.httpCookieStorage = nil
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  /// Names a part's task, so its outcome finds the part.
  static func taskDescription(jobID: String, part: Int) -> String {
    "\(jobID)/\(part)"
  }

  static func part(fromTaskDescription description: String?) -> (jobID: String, part: Int)? {
    guard let description, let slash = description.lastIndex(of: "/"),
      let part = Int(description[description.index(after: slash)...])
    else { return nil }
    return (String(description[..<slash]), part)
  }

  /// Records each finished transfer in the ledger.
  public final class Delegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let store: BackgroundUploadLedgerStore
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var finishedEvents: (@Sendable () -> Void)?

    public init(store: BackgroundUploadLedgerStore = .shared) {
      self.store = store
    }

    /// Called once iOS has delivered every event of a session it woke the app for.
    public func onFinishedEvents(_ handler: @escaping @Sendable () -> Void) {
      lock.withLock { finishedEvents = handler }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      lock.withLock { bodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      let body = lock.withLock { bodies.removeValue(forKey: task.taskIdentifier) } ?? Data()
      guard let (jobID, index) = BackgroundUploadTransfers.part(fromTaskDescription: task.taskDescription) else { return }
      let nsError = error as NSError?
      // This process lost the session to the other one, which reports the real outcome.
      if nsError?.domain == NSURLErrorDomain, nsError?.code == NSURLErrorBackgroundSessionInUseByAnotherProcess {
        return
      }
      let response = task.response as? HTTPURLResponse
      let status = response?.statusCode ?? 0
      let outcome = Self.outcome(status: status, body: body, error: nsError)
      store.update { ledger in
        if status == 429, let account = ledger.job(withID: jobID)?.accountEmail {
          let retryAfter = response?.value(forHTTPHeaderField: "Retry-After")
          ledger.noteRateLimit(accountEmail: account, retryAfter: Self.retryDelay(retryAfter))
        } else if outcome.token != nil, let account = ledger.job(withID: jobID)?.accountEmail,
          !ledger.isRateLimited(accountEmail: account)
        {
          ledger.rateLimits[account] = nil
        }
        ledger.updatePart(jobID: jobID, index: index) { part in
          guard part.state == .sending else { return }
          part.state = outcome.token == nil ? .failed : .sent
          part.finalizeToken = outcome.token
          part.error = outcome.error
        }
      }
      let sent = ByteFormat.string(task.countOfBytesSent)
      BackgroundUploadLog.write("transfer \(jobID)/\(index): HTTP \(status), \(sent) sent\(outcome.error.map { ", \($0)" } ?? "")")
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
      let handler = lock.withLock {
        defer { finishedEvents = nil }
        return finishedEvents
      }
      handler?()
    }

    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
      guard let value else { return 0 }
      if let seconds = TimeInterval(value), seconds.isFinite { return max(0, seconds) }
      let format = DateFormatter()
      format.locale = Locale(identifier: "en_US_POSIX")
      format.timeZone = TimeZone(secondsFromGMT: 0)
      format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      return max(0, format.date(from: value)?.timeIntervalSince(now) ?? 0)
    }

    /// A 2xx carries Scotty's finalize token; anything else fails the part, which a later
    /// status query may still find complete.
    static func outcome(status: Int, body: Data, error: NSError?) -> (token: Data?, error: String?) {
      if let error { return (nil, "\(error.domain) \(error.code)") }
      guard (200...299).contains(status) else { return (nil, "HTTP \(status)") }
      guard (try? ScottyFinalizeToken.parse(body)) != nil else { return (nil, "Unreadable upload response") }
      return (body, nil)
    }
  }
}
