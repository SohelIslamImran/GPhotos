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
  /// Posted, off the main thread, when Low Data Mode turns on or off.
  public static let didChangeConstrained = Notification.Name("NetworkStatusMonitor.didChangeConstrained")
  public static let didChangeConnectivity = Notification.Name("NetworkStatusMonitor.didChangeConnectivity")

  private let monitor = NWPathMonitor()
  private let lock = NSLock()
  private var _isExpensive = false
  private var _isConstrained = false
  private var _isConnected = true

  /// `watches` is off in tests, which drive `update` themselves.
  init(watches: Bool = true) {
    guard watches else { return }
    monitor.pathUpdateHandler = { [weak self] path in
      self?.update(
        isConnected: path.status == .satisfied, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
    let queue = DispatchQueue(label: "org.gphotosapp.gphotos.network-monitor", qos: .utility)
    monitor.start(queue: queue)
  }

  func update(isConnected: Bool, isExpensive: Bool, isConstrained: Bool) {
    let (reconnected, expensiveChanged, constrainedChanged, connectivityChanged) = lock.withLock {
      let wasConnected = _isConnected
      let wasExpensive = _isExpensive
      let wasConstrained = _isConstrained
      _isExpensive = isExpensive
      _isConstrained = isConstrained
      _isConnected = isConnected
      return (
        _isConnected && (!wasConnected || (wasExpensive && !_isExpensive)),
        wasExpensive != _isExpensive,
        wasConstrained != _isConstrained,
        wasConnected != _isConnected
      )
    }
    if expensiveChanged {
      NotificationCenter.default.post(name: Self.didChangeExpensive, object: self)
    }
    if constrainedChanged {
      NotificationCenter.default.post(name: Self.didChangeConstrained, object: self)
    }
    if connectivityChanged {
      NotificationCenter.default.post(name: Self.didChangeConnectivity, object: self)
    }
    if reconnected {
      NotificationCenter.default.post(name: Self.didReconnect, object: self)
    }
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
