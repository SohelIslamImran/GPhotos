import Foundation
import Network

/// Monitors network connectivity, expensive (cellular/metered), and constrained (Low Data Mode) statuses.
public final class NetworkStatusMonitor: @unchecked Sendable {
  public static let shared = NetworkStatusMonitor()
  /// Posted, off the main thread, when the network comes back after being unavailable or
  /// moves from a metered network (cellular, hotspot) to an unmetered one.
  public static let didReconnect = Notification.Name("NetworkStatusMonitor.didReconnect")
  /// Posted, off the main thread, when the network becomes metered or stops being metered.
  public static let didChangeExpensive = Notification.Name("NetworkStatusMonitor.didChangeExpensive")
  public static let didChangeConnectivity = Notification.Name("NetworkStatusMonitor.didChangeConnectivity")

  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var _isExpensive = false
  private var _isConstrained = false
  private var _isConnected = true

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let (reconnected, expensiveChanged, connectivityChanged) = self.lock.withLock {
        let wasConnected = self._isConnected
        let wasExpensive = self._isExpensive
        self._isExpensive = path.isExpensive
        self._isConstrained = path.isConstrained
        self._isConnected = (path.status == .satisfied)
        return (
          self._isConnected && (!wasConnected || (wasExpensive && !self._isExpensive)),
          wasExpensive != self._isExpensive,
          wasConnected != self._isConnected
        )
      }
      if expensiveChanged {
        NotificationCenter.default.post(name: Self.didChangeExpensive, object: nil)
      }
      if connectivityChanged {
        NotificationCenter.default.post(name: Self.didChangeConnectivity, object: nil)
      }
      if reconnected {
        NotificationCenter.default.post(name: Self.didReconnect, object: nil)
      }
    }
    let queue = DispatchQueue(label: "org.gphotosapp.gphotos.network-monitor", qos: .utility)
    monitor.start(queue: queue)
  }

  public var isExpensive: Bool {
    lock.withLock { _isExpensive }
  }

  public var isConstrained: Bool {
    lock.withLock { _isConstrained }
  }

  public var isConnected: Bool {
    lock.withLock { _isConnected }
  }
}
