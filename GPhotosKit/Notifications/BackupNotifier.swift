import Foundation
import UserNotifications

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

public enum BackupNotificationEvent: Equatable, Sendable {
  case backupFinished(count: Int)
  case batchFailed(uploaded: Int, failed: Int)
  case accountNeedsSignIn(email: String)
  case accountOutOfStorage(email: String)
  case secondaryCopiesUpdated(count: Int, email: String)
}

public struct NotificationCoalescer: Sendable {
  public static func eventForBatch(
    uploadedCount: Int,
    failedCount: Int,
    authErrorEmail: String?,
    storageFullEmail: String? = nil,
    isAppFrontmost: Bool
  ) -> BackupNotificationEvent? {
    guard !isAppFrontmost else { return nil }
    if let authErrorEmail {
      return .accountNeedsSignIn(email: authErrorEmail)
    }
    if let storageFullEmail {
      return .accountOutOfStorage(email: storageFullEmail)
    }
    if failedCount > 0 {
      return .batchFailed(uploaded: uploadedCount, failed: failedCount)
    }
    if uploadedCount >= 1 {
      return .backupFinished(count: uploadedCount)
    }
    return nil
  }

  public static func eventForSecondaryWindow(
    copiedCount: Int,
    secondaryEmail: String,
    hasAuthError: Bool,
    isAppFrontmost: Bool
  ) -> BackupNotificationEvent? {
    guard !isAppFrontmost else { return nil }
    if hasAuthError {
      return .accountNeedsSignIn(email: secondaryEmail)
    }
    if copiedCount >= 1 {
      return .secondaryCopiesUpdated(count: copiedCount, email: secondaryEmail)
    }
    return nil
  }

  public static func formatBackupFinishedBody(count: Int) -> String {
    let itemString = count == 1 ? "1 item" : "\(count.formatted()) items"
    return "\(itemString) backed up to Google Photos."
  }

  public static func formatBatchFailedBody(count: Int) -> String {
    let itemString = count == 1 ? "1 item" : "\(count.formatted()) items"
    return "\(itemString) failed. Open GPhotos to retry."
  }

  public static func formatAccountNeedsSignInBody(email: String) -> String {
    "\(email) needs you to sign in again to keep backing up."
  }

  public static func formatAccountOutOfStorageBody(email: String) -> String {
    "\(email) is out of storage. Free up space in Google Photos to keep backing up."
  }

  public static func formatSecondaryCopiesUpdatedBody(count: Int, email: String) -> String {
    let itemString = count == 1 ? "1 item" : "\(count.formatted()) items"
    return "\(itemString) copied to \(email)."
  }

  public struct Content: Equatable, Sendable {
    public var title: String
    public var body: String
    public var interruptionLevel: UNNotificationInterruptionLevel
    public var categoryIdentifier: String
    public var threadIdentifier: String
    public var identifier: String
    public var destination: String?

    public init(
      title: String,
      body: String,
      interruptionLevel: UNNotificationInterruptionLevel,
      categoryIdentifier: String,
      threadIdentifier: String,
      identifier: String,
      destination: String? = nil
    ) {
      self.title = title
      self.body = body
      self.interruptionLevel = interruptionLevel
      self.categoryIdentifier = categoryIdentifier
      self.threadIdentifier = threadIdentifier
      self.identifier = identifier
      self.destination = destination
    }
  }

  public static func content(for event: BackupNotificationEvent) -> Content {
    switch event {
    case .backupFinished(let count):
      return Content(
        title: "Backup Complete",
        body: formatBackupFinishedBody(count: count),
        interruptionLevel: .passive,
        categoryIdentifier: BackupNotifier.backupFinishedCategoryIdentifier,
        threadIdentifier: "backup.status",
        identifier: "backup.complete",
        destination: nil
      )
    case .batchFailed(let uploaded, let failed):
      let failures = formatBatchFailedBody(count: failed)
      return Content(
        title: "Some Items Didn't Upload",
        body: uploaded > 0 ? "\(formatBackupFinishedBody(count: uploaded)) \(failures)" : failures,
        interruptionLevel: .active,
        categoryIdentifier: BackupNotifier.failedCategoryIdentifier,
        threadIdentifier: "backup.failures",
        identifier: "backup.failed",
        destination: BackupNotifier.destinationFailed
      )
    case .accountNeedsSignIn(let email):
      return Content(
        title: "Sign In Again",
        body: formatAccountNeedsSignInBody(email: email),
        interruptionLevel: .active,
        categoryIdentifier: BackupNotifier.accountAuthCategoryIdentifier,
        threadIdentifier: "account.auth",
        identifier: "account.auth.\(email)",
        destination: BackupNotifier.destinationAccount
      )
    case .accountOutOfStorage(let email):
      return Content(
        title: "Google Account Full",
        body: formatAccountOutOfStorageBody(email: email),
        interruptionLevel: .active,
        categoryIdentifier: BackupNotifier.accountStorageCategoryIdentifier,
        threadIdentifier: "account.storage",
        identifier: "account.storage.\(email)",
        destination: nil
      )
    case .secondaryCopiesUpdated(let count, let email):
      return Content(
        title: "Copies Updated",
        body: formatSecondaryCopiesUpdatedBody(count: count, email: email),
        interruptionLevel: .passive,
        categoryIdentifier: BackupNotifier.secondaryCopyCategoryIdentifier,
        threadIdentifier: "secondary.copy",
        identifier: "secondary.copy.\(email)",
        destination: nil
      )
    }
  }
}

@MainActor
public final class BackupNotifier {
  public static let shared = BackupNotifier()

  nonisolated public static let retryActionIdentifier = "backup.action.retry"
  nonisolated public static let failedCategoryIdentifier = "backup.failed"
  nonisolated public static let backupFinishedCategoryIdentifier = "backup.complete"
  nonisolated public static let accountAuthCategoryIdentifier = "account.auth"
  nonisolated public static let secondaryCopyCategoryIdentifier = "secondary.copy"
  nonisolated public static let accountStorageCategoryIdentifier = "account.storage"

  nonisolated public static let destinationKey = "destination"
  nonisolated public static let destinationFailed = "failed"
  nonisolated public static let destinationAccount = "account"
  nonisolated public static let emailKey = "email"

  /// Optional override for checking whether the app is frontmost (used in unit tests).
  public var isFrontmostOverride: (@MainActor () -> Bool)?

  /// Optional hook for notification posting (used in unit tests).
  public var postNotificationHook: (@MainActor (UNNotificationRequest) async throws -> Void)?

  public var isAppFrontmost: Bool {
    if let override = isFrontmostOverride {
      return override()
    }
    #if os(iOS)
      return UIApplication.shared.applicationState == .active
    #elseif os(macOS)
      return NSApp.isActive
    #else
      return false
    #endif
  }

  /// Accounts already told to sign in again. Idle windows retry every 30 minutes, so
  /// without this a broken account would re-alert each time.
  private var signInNoticeEmails = Set<String>()
  /// Accounts already told they are full. Each background pass stops at the first item, so
  /// without this every pass would alert again; a batch that uploads clears it.
  private var storageNoticeEmails = Set<String>()

  public init() {}

  /// Allows the next sign-in notice for `email`, once it uploads again.
  public func clearSignInNotice(for email: String) {
    if signInNoticeEmails.remove(email) != nil {
      UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["account.auth.\(email)"])
    }
  }

  public func registerCategories() {
    let retryAction = UNNotificationAction(
      identifier: Self.retryActionIdentifier,
      title: String(localized: "Retry"),
      options: [.foreground]
    )
    let failedCategory = UNNotificationCategory(
      identifier: Self.failedCategoryIdentifier,
      actions: [retryAction],
      intentIdentifiers: [],
      options: []
    )
    let completeCategory = UNNotificationCategory(
      identifier: Self.backupFinishedCategoryIdentifier,
      actions: [],
      intentIdentifiers: [],
      options: []
    )
    let authCategory = UNNotificationCategory(
      identifier: Self.accountAuthCategoryIdentifier,
      actions: [],
      intentIdentifiers: [],
      options: []
    )
    let secondaryCategory = UNNotificationCategory(
      identifier: Self.secondaryCopyCategoryIdentifier,
      actions: [],
      intentIdentifiers: [],
      options: []
    )
    let storageCategory = UNNotificationCategory(
      identifier: Self.accountStorageCategoryIdentifier,
      actions: [],
      intentIdentifiers: [],
      options: []
    )
    UNUserNotificationCenter.current().setNotificationCategories([
      failedCategory, completeCategory, authCategory, secondaryCategory, storageCategory,
    ])
  }

  public func requestAuthorization() async {
    let center = UNUserNotificationCenter.current()
    guard isAppFrontmost, await center.notificationSettings().authorizationStatus == .notDetermined else { return }
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  public func notifyBatchCompletion(
    uploadedCount: Int,
    failedCount: Int,
    authErrorEmail: String?,
    storageFullEmail: String? = nil
  ) async {
    if storageFullEmail == nil, uploadedCount > 0 { storageNoticeEmails.removeAll() }
    guard
      let event = NotificationCoalescer.eventForBatch(
        uploadedCount: uploadedCount,
        failedCount: failedCount,
        authErrorEmail: authErrorEmail,
        storageFullEmail: storageFullEmail,
        isAppFrontmost: isAppFrontmost
      )
    else { return }

    await postEvent(event)
  }

  public func notifySecondaryCopyCompletion(
    copiedCount: Int,
    secondaryEmail: String,
    hasAuthError: Bool
  ) async {
    guard
      let event = NotificationCoalescer.eventForSecondaryWindow(
        copiedCount: copiedCount,
        secondaryEmail: secondaryEmail,
        hasAuthError: hasAuthError,
        isAppFrontmost: isAppFrontmost
      )
    else { return }

    await postEvent(event)
  }

  public func notifyAccountNeedsSignIn(email: String) async {
    guard !isAppFrontmost else { return }
    await postEvent(.accountNeedsSignIn(email: email))
  }

  /// Called by the process that committed the uploads, once per extension run or app drain.
  public func notifyBackgroundUploadCompletion(
    uploadedCount: Int, failedCount: Int, accountError: BackupNotificationEvent?, fromExtension: Bool
  ) async {
    guard fromExtension || !isAppFrontmost else { return }
    if let accountError {
      await postEvent(accountError)
    } else if let summary = NotificationCoalescer.eventForBatch(
      uploadedCount: uploadedCount, failedCount: failedCount, authErrorEmail: nil, isAppFrontmost: false)
    {
      await postEvent(summary)
    }
  }

  private func postEvent(_ event: BackupNotificationEvent) async {
    let payload = NotificationCoalescer.content(for: event)
    let center = UNUserNotificationCenter.current()
    let quietPeriod: TimeInterval? =
      switch event {
      case .accountNeedsSignIn, .accountOutOfStorage: 24 * 60 * 60
      case .batchFailed: 60 * 60
      default: nil
      }
    if let quietPeriod, postNotificationHook == nil {
      let delivered = await center.deliveredNotifications()
      if delivered.contains(where: {
        $0.request.identifier == payload.identifier && $0.request.content.body == payload.body
          && Date().timeIntervalSince($0.date) < quietPeriod
      }) {
        return
      }
    }

    if case .accountNeedsSignIn(let email) = event {
      guard signInNoticeEmails.insert(email).inserted else { return }
    }
    if case .accountOutOfStorage(let email) = event {
      guard storageNoticeEmails.insert(email).inserted else { return }
    }
    let content = UNMutableNotificationContent()
    content.title = payload.title
    content.body = payload.body
    content.categoryIdentifier = payload.categoryIdentifier
    content.threadIdentifier = payload.threadIdentifier
    content.interruptionLevel = payload.interruptionLevel
    if let destination = payload.destination {
      content.userInfo[Self.destinationKey] = destination
    }
    if case .accountNeedsSignIn(let email) = event {
      content.userInfo[Self.emailKey] = email
    }

    let request = UNNotificationRequest(identifier: payload.identifier, content: content, trigger: nil)
    do {
      if let hook = postNotificationHook {
        try await hook(request)
      } else {
        try await center.add(request)
      }
    } catch {
      if case .accountNeedsSignIn(let email) = event { signInNoticeEmails.remove(email) }
      if case .accountOutOfStorage(let email) = event { storageNoticeEmails.remove(email) }
    }
  }
}
