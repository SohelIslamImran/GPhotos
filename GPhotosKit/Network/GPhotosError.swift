import Foundation
import Security

public enum GPhotosError: Error, Sendable, Equatable {
  case notAuthenticated
  case tokenBindingUnsupported
  case tokenBindingFailed(String)
  case authFailed(status: Int, body: String)
  case uploadTokenMissingHeader
  case httpError(status: Int, body: String)
  case protobufDecode(String)
  case networkUnavailable
  /// The item needs this many bytes of free space to be copied out for upload.
  case notEnoughSpace(needed: Int64)
  case cancelled
  case assetExportFailed(underlying: String)
  case fileReadFailed(String)
  case missingCredential
  case invalidCredential(String)
  case keychain(operation: String, status: OSStatus)
  /// Google says the account has no storage left; no upload can succeed until space is freed.
  case storageFull
  /// The original is only in iCloud and this pass may not download it; the item waits.
  case iCloudDownloadDeferred
  /// The account signs in but Google Photos refuses it, as when a Workspace admin has
  /// turned Google Photos off.
  case photosUnavailable

  public var isRetryable: Bool {
    switch self {
    case .httpError(let status, _):
      return status == 429 || (500...599).contains(status)
    case .networkUnavailable:
      return true
    case .cancelled:
      return false
    case .notAuthenticated, .tokenBindingUnsupported, .tokenBindingFailed, .authFailed, .uploadTokenMissingHeader,
      .protobufDecode, .assetExportFailed, .fileReadFailed, .missingCredential, .invalidCredential, .keychain,
      .storageFull, .iCloudDownloadDeferred, .photosUnavailable, .notEnoughSpace:
      return false
    }
  }

  public static func from(urlError: URLError) -> GPhotosError {
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost:
      return .networkUnavailable
    case .timedOut:
      return .networkUnavailable
    case .cancelled:
      return .cancelled
    // The item's file, not the network: it fails rather than holding up the rest.
    case .fileDoesNotExist, .fileIsDirectory, .cannotOpenFile, .noPermissionsToReadFile:
      return .fileReadFailed(urlError.localizedDescription)
    default:
      return .networkUnavailable
    }
  }
}

extension GPhotosError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notAuthenticated:
      return "Not authenticated. Save a credential first."
    case .tokenBindingUnsupported:
      return "Token-binding credentials are not supported. Use a plain credential string."
    case .tokenBindingFailed(let detail):
      return "Token binding error: \(detail)"
    case .authFailed(let status, let detail):
      return "Authentication failed (HTTP \(status)): \(detail)"
    case .uploadTokenMissingHeader:
      return "Upload response missing X-GUploader-UploadID."
    case .httpError(let status, let body):
      return "HTTP \(status): \(body)"
    case .protobufDecode(let detail):
      return "Protobuf error: \(detail)"
    case .networkUnavailable:
      return "Network unavailable."
    case .notEnoughSpace(let needed):
      if needed <= 0 { return "Not enough space to prepare this item. Free up space, then retry." }
      return "Not enough space to prepare this item. Needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free."
    case .cancelled:
      return "Cancelled."
    case .assetExportFailed(let underlying):
      return "Asset export failed: \(underlying)"
    case .fileReadFailed(let detail):
      return "File error: \(detail)"
    case .missingCredential:
      return "No credential in Keychain."
    case .invalidCredential(let detail):
      return "Invalid credential: \(detail)"
    case .iCloudDownloadDeferred:
      return "Waiting to download this item from iCloud."
    case .photosUnavailable:
      return "Google Photos isn’t available for this account. Check that it’s turned on, then sign in again."
    case .storageFull:
      return "Your Google account is out of storage. Free up space in Google Photos, then try again."
    case .keychain(_, errSecMissingEntitlement):
      return "This build can't access the keychain. Reinstall a signed build."
    case .keychain(let operation, let status):
      let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Keychain \(operation) failed: \(reason)"
    }
  }
}
