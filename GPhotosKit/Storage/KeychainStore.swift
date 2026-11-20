import Foundation
import Security

public struct GoogleAccount: Identifiable, Codable, Hashable, Sendable {
  public var id: String { email }
  public let email: String
  public let androidId: String
  public let credentialString: String
  public let addedDate: Date
  public var mirrorEnabled: Bool

  public init(
    email: String,
    androidId: String,
    credentialString: String,
    addedDate: Date = Date(),
    mirrorEnabled: Bool = true
  ) {
    self.email = email
    self.androidId = androidId
    self.credentialString = credentialString
    self.addedDate = addedDate
    self.mirrorEnabled = mirrorEnabled
  }
}

public struct KeychainAccountPayload: Codable, Sendable, Equatable {
  public var accounts: [GoogleAccount]
  public var primaryEmail: String?

  public init(accounts: [GoogleAccount] = [], primaryEmail: String? = nil) {
    self.accounts = accounts
    self.primaryEmail = primaryEmail
  }
}

/// Stores the configured Google Photos accounts and the primary account pointer.
public enum KeychainStore {
  private static let service = AppGroupConstants.keychainService
  private static let accountItemKey = "google-photos-accounts-list"

  /// The master token grants full access to the user's Google Photos library, so the
  /// item is device-only rather than restored from an iCloud or iTunes backup.
  private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

  private static func itemQuery() -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accountItemKey,
    ]
    #if os(macOS)
      // The file-based login keychain ignores accessibility classes; the data-protection
      // keychain honors them, matching iOS.
      query[kSecUseDataProtectionKeychain as String] = true
    #else
      // The App Group doubles as a keychain group, so the photo upload extension, which
      // iOS runs after the app is closed, can sign in as the account too.
      query[kSecAttrAccessGroup as String] = AppGroupConstants.identifier
    #endif
    return query
  }

  public static func loadAccounts() throws -> (accounts: [GoogleAccount], primaryEmail: String?) {
    var query = itemQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return ([], nil) }
    guard status == errSecSuccess, let data = result as? Data else {
      throw GPhotosError.keychain(operation: "read", status: status)
    }
    let payload = decodePayload(data)
    return (payload.accounts, payload.primaryEmail)
  }

  /// An item that no longer decodes holds no usable account, so it reads as signed out
  /// and the next sign-in overwrites it. Only a failed keychain read is an error, which
  /// the app reports as "Can't Read Your Account".
  static func decodePayload(_ data: Data) -> KeychainAccountPayload {
    (try? JSONDecoder().decode(KeychainAccountPayload.self, from: data)) ?? KeychainAccountPayload()
  }

  public static func saveAccounts(_ accounts: [GoogleAccount], primaryEmail: String?) throws {
    let payload = KeychainAccountPayload(accounts: accounts, primaryEmail: primaryEmail)
    let data = try JSONEncoder().encode(payload)
    let status = SecItemUpdate(
      itemQuery() as CFDictionary,
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: accessibility,
      ] as CFDictionary
    )
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var add = itemQuery()
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = accessibility
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else {
        throw GPhotosError.keychain(operation: "write", status: addStatus)
      }
    default:
      throw GPhotosError.keychain(operation: "update", status: status)
    }
  }

  public static func deleteAccounts() throws {
    let status = SecItemDelete(itemQuery() as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw GPhotosError.keychain(operation: "delete", status: status)
    }
  }

  public static func setPrimary(email: String) throws {
    let (accounts, _) = try loadAccounts()
    guard accounts.contains(where: { $0.email == email }) else { return }
    try saveAccounts(accounts, primaryEmail: email)
  }

  public static func removeAccount(email: String) throws {
    let (accounts, primaryEmail) = try loadAccounts()
    let filtered = accounts.filter { $0.email != email }
    if filtered.isEmpty {
      try deleteAccounts()
    } else {
      let newPrimary = (primaryEmail == email) ? filtered.first?.email : primaryEmail
      try saveAccounts(filtered, primaryEmail: newPrimary)
    }
  }

  public static func setMirrorEnabled(email: String, enabled: Bool) throws {
    var (accounts, primaryEmail) = try loadAccounts()
    guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
    accounts[index].mirrorEnabled = enabled
    try saveAccounts(accounts, primaryEmail: primaryEmail)
  }

  public static func loadAccount() throws -> GoogleAccount? {
    let (accounts, primaryEmail) = try loadAccounts()
    if let primaryEmail, let found = accounts.first(where: { $0.email == primaryEmail }) {
      return found
    }
    return accounts.first
  }

  public static func saveAccount(_ account: GoogleAccount) throws {
    var (accounts, primaryEmail) = try loadAccounts()
    if let index = accounts.firstIndex(where: { $0.email == account.email }) {
      accounts[index] = account
    } else {
      accounts.append(account)
    }
    if primaryEmail == nil {
      primaryEmail = account.email
    }
    try saveAccounts(accounts, primaryEmail: primaryEmail)
  }

  public static func deleteAccount() throws {
    try deleteAccounts()
  }
}
