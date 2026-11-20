import Foundation
import Testing

@testable import GPhotosKit

@Suite("Google error responses")
struct NetworkErrorTests {
  /// `google.rpc.Status { code, message }` as Google sends it.
  private func status(code: Int64, message: String) -> Data {
    var writer = ProtobufWriter()
    writer.writeInt64(fieldNumber: 1, code)
    writer.writeString(fieldNumber: 2, message)
    return writer.data
  }

  @Test("A status body decodes to its code and message")
  func decodesStatus() {
    let decoded = GooglePhotosMessages.decodeRPCStatus(status(code: 3, message: "Invalid blueprint"))
    #expect(decoded == GooglePhotosMessages.RPCStatus(code: 3, message: "Invalid blueprint"))
  }

  @Test("Bodies that are not a status do not decode as one")
  func rejectsNonStatus() {
    #expect(GooglePhotosMessages.decodeRPCStatus(Data()) == nil)
    #expect(GooglePhotosMessages.decodeRPCStatus(Data("<html>Error</html>".utf8)) == nil)
    #expect(GooglePhotosMessages.decodeRPCStatus(status(code: 0, message: "OK")) == nil)
  }

  @Test("Error detail prefers the status message, keeps text, drops binary")
  func errorDetail() {
    #expect(GooglePhotosMessages.errorDetail(status(code: 3, message: "Invalid blueprint")) == "Invalid blueprint")
    #expect(GooglePhotosMessages.errorDetail(Data("  Bad Request \n".utf8)) == "Bad Request")
    #expect(GooglePhotosMessages.errorDetail(Data([0x08, 0x00, 0xFF, 0xFE, 0x01])) == "")
  }

  @Test("RESOURCE_EXHAUSTED means a full account, except on a 429")
  func storageFull() {
    let exhausted = status(code: 8, message: "Quota exceeded")
    #expect(throws: GPhotosError.storageFull) {
      try GooglePhotosMobileClient.throwHTTPError(status: 400, data: exhausted)
    }
    #expect(throws: GPhotosError.httpError(status: 429, body: "Quota exceeded")) {
      try GooglePhotosMobileClient.throwHTTPError(status: 429, data: exhausted)
    }
    #expect(GooglePhotosMobileClient.isPermanentUploadFailure(GPhotosError.storageFull))
    #expect(!GPhotosError.storageFull.isRetryable)
  }

  @Test("A full account is announced after sign-in problems, before failures")
  func storageNotificationPrecedence() {
    let full = NotificationCoalescer.eventForBatch(
      uploadedCount: 3, failedCount: 1, authErrorEmail: nil, storageFullEmail: "a@gmail.com", isAppFrontmost: false)
    #expect(full == .accountOutOfStorage(email: "a@gmail.com"))
    let auth = NotificationCoalescer.eventForBatch(
      uploadedCount: 0, failedCount: 1, authErrorEmail: "a@gmail.com", storageFullEmail: "a@gmail.com",
      isAppFrontmost: false)
    #expect(auth == .accountNeedsSignIn(email: "a@gmail.com"))
  }
}
