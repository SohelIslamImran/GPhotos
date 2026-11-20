import Foundation
import Photos
import Testing

@testable import GPhotosKit

@Suite("Asset export resource choice")
struct AssetExportTests {
  @Test("Disk-full errors from PhotoKit, Cocoa, and a wrapped write are explained consistently")
  func outOfSpaceErrors() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let errors = [
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
      NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.notEnoughSpace.rawValue),
      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix]),
    ]
    for error in errors {
      #expect(AssetExportService.exportError(error) == .notEnoughSpace(needed: 0))
    }
  }

  @Test("A silent PhotoKit request times out and rejects a late request identifier")
  func silentRequestTimesOut() async throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let gate = ResourceRequestGate(fileHandle: try FileHandle(forWritingTo: url))
    #expect(!gate.timeOutIfIdle(for: .seconds(120)))
    #expect(gate.timeOutIfIdle(for: .seconds(120), now: .now.advanced(by: .seconds(121))))
    #expect(!gate.setRequestID(123))
    await #expect(throws: GPhotosError.assetExportFailed(underlying: "Photos stopped responding. Tap Retry.")) {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        gate.install(continuation)
      }
    }
  }

  @Test("A failed export write rejects a late PhotoKit request and preserves its error")
  func writeFailureCancelsRequest() async throws {
    let url = TestTemporaryDirectory.root.appendingPathComponent(UUID().uuidString)
    try Data().write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let handle = try FileHandle(forWritingTo: url)
    try handle.close()
    let gate = ResourceRequestGate(fileHandle: handle)
    gate.write(Data([1]))
    #expect(!gate.setRequestID(123))
    gate.resume(.success(()))
    do {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        gate.install(continuation)
      }
      Issue.record("The failed write was reported as a successful export")
    } catch {
      guard case .assetExportFailed = error as? GPhotosError else {
        Issue.record("The export's write error was lost: \(error)")
        return
      }
    }
  }

  private func pick(_ types: [PHAssetResourceType], mediaType: PHAssetMediaType, edited: Bool) -> PHAssetResourceType? {
    AssetExportService.firstResource(
      in: types, type: { $0 },
      preferring: AssetExportService.primaryResourceTypes(mediaType: mediaType, edited: edited))
  }

  @Test("An edited video uploads its rendered video, never its rendered still")
  func editedVideoSkipsStill() {
    #expect(pick([.fullSizePhoto, .video, .fullSizeVideo], mediaType: .video, edited: true) == .fullSizeVideo)
    #expect(pick([.fullSizePhoto, .video], mediaType: .video, edited: true) == .video)
    #expect(pick([.fullSizePhoto], mediaType: .video, edited: true) == nil)
  }

  @Test("An edited photo uploads its render, an unedited one its original")
  func photoFollowsEditState() {
    #expect(pick([.photo, .fullSizePhoto], mediaType: .image, edited: true) == .fullSizePhoto)
    #expect(pick([.fullSizePhoto, .photo], mediaType: .image, edited: false) == .photo)
    #expect(pick([.fullSizePhoto], mediaType: .image, edited: false) == .fullSizePhoto)
  }

  @Test("Live Photo motion follows the edit state")
  func motionFollowsEditState() {
    let types: [PHAssetResourceType] = [.pairedVideo, .fullSizePairedVideo]
    let edited = AssetExportService.firstResource(
      in: types, type: { $0 }, preferring: AssetExportService.pairedVideoResourceTypes(edited: true))
    let unedited = AssetExportService.firstResource(
      in: types, type: { $0 }, preferring: AssetExportService.pairedVideoResourceTypes(edited: false))
    #expect(edited == .fullSizePairedVideo)
    #expect(unedited == .pairedVideo)
  }

  @Test("An edit's original is the camera's file, never a render")
  func uneditedOriginalIsCameraFile() {
    #expect(AssetExportService.uneditedOriginalType(mediaType: .image) == .photo)
    #expect(AssetExportService.uneditedOriginalType(mediaType: .video) == .video)
  }

  @Test("A render goes up under the camera's name with its own file type")
  func renderKeepsOriginalName() {
    #expect(AssetExportService.uploadFilename(original: "IMG_0001.HEIC", rendition: "FullSizeRender.heic") == "IMG_0001.HEIC")
    #expect(AssetExportService.uploadFilename(original: "IMG_0001.HEIC", rendition: "FullSizeRender.jpg") == "IMG_0001.JPG")
    #expect(AssetExportService.uploadFilename(original: "img_0001.mov", rendition: "FullSizeRender.MP4") == "img_0001.mp4")
    #expect(AssetExportService.uploadFilename(original: nil, rendition: "FullSizeRender.heic") == "FullSizeRender.heic")
    #expect(AssetExportService.uploadFilename(original: "IMG_0001.MOV", rendition: "") == "IMG_0001.MOV")
  }
}
