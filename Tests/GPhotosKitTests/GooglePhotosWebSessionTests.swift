import Foundation
import Testing

@testable import GPhotosKit

@Suite("Google Photos Locked Folder web requests")
struct GooglePhotosWebSessionTests {
  @Test func requestMatchesToolkitShape() throws {
    let request = try LockedFolderWebRequest(
      keys: ["one/two", "é +&"], sourcePath: "/u/0/", sid: "-1+2", build: "photos&1", token: "a+ b&/")

    #expect(
      request.url.absoluteString
        == "https://photos.google.com/_/PhotosUi/data/batchexecute?rpcids=StLnCe&source-path=%2Fu%2F0%2F&f.sid=-1%2B2&bl=photos%261&pageId=none&rt=c"
    )
    #expect(
      request.body
        == "f.req=%5B%5B%5B%22StLnCe%22%2C%22%5B%5B%5C%22one%2Ftwo%5C%22%2C%5C%22%C3%A9%20%2B%26%5C%22%5D%2C%5B%5D%5D%22%2Cnull%2C%22generic%22%5D%5D%5D&at=a%2B%20b%26%2F&"
    )
  }

  @Test func acceptsOnlyPhotosEndpointPrefixes() throws {
    #expect(LockedFolderWebRequest.isValidPath("/_/PhotosUi/"))
    #expect(LockedFolderWebRequest.isValidPath("/u/1/_/PhotosUi/"))
    for path in ["", "/u//_/PhotosUi/", "/u/x/_/PhotosUi/", "//evil.com/_/PhotosUi/", "/u/1/../_/PhotosUi/", "/_/Other/"] {
      #expect(!LockedFolderWebRequest.isValidPath(path))
    }
    let request = try LockedFolderWebRequest(
      keys: ["k"], path: "/u/1/_/PhotosUi/", sourcePath: "/u/1/", sid: "s", build: "b", token: "t")
    #expect(request.url.path() == "/u/1/_/PhotosUi/data/batchexecute")
    #expect(throws: GooglePhotosWebError.unavailable) {
      try LockedFolderWebRequest(keys: ["k"], path: "//evil.com/", sourcePath: "/", sid: "s", build: "b", token: "t")
    }
  }

  @Test func acceptsOnlyTheMovesNonNullPayload() throws {
    let response = """
      )]}'

      27
      [["wrb.fr","unrelated",null]]
      44
      [["di",1],["wrb.fr","StLnCe","[]",null,null,null,"generic"]]
      """
    try LockedFolderWebRequest.checkResponse(response)
  }

  @Test(arguments: [
    "",
    #"[["wrb.fr","other","[]"]]"#,
    #"[["wrb.fr","StLnCe"]]"#,
    #"[["wrb.fr","StLnCe",null]]"#,
    #"[["wrb.fr","StLnCe","null"]]"#,
    #"[["wrb.fr","StLnCe","broken"]]"#,
  ])
  func rejectsResponsesWithoutConfirmation(response: String) {
    #expect(throws: GooglePhotosWebError.rejected) { try LockedFolderWebRequest.checkResponse(response) }
  }

  @Test func batchesAtOneHundred() {
    let keys = Array(0..<201)
    let batches = LockedFolderWebRequest.batches(of: keys)
    #expect(batches.map(\.count) == [100, 100, 1])
    #expect(batches.flatMap { $0 } == keys)
    #expect(LockedFolderWebRequest.batches(of: [String]()).isEmpty)
  }

  @Test func excludesLockedTrashedAndUnaddressableItems() {
    let items = [
      item("available"), item("locked"), item("trashed", trashedAt: Date()), item("unaddressable", dedupKey: ""),
      item("available"), item("last"),
    ]
    #expect(CloudLibrary.lockableItems(items, excluding: ["locked"]).map(\.mediaKey) == ["available", "last"])
  }

  @Test func accountStoreIdentifierIgnoresEmailCase() {
    let id = GooglePhotosWebSession.identifier(for: "Person@example.com")
    #expect(id == GooglePhotosWebSession.identifier(for: "person@EXAMPLE.COM"))
    #expect(id != GooglePhotosWebSession.identifier(for: "different@example.com"))
  }

  private func item(_ key: String, dedupKey: String = "dedup", trashedAt: Date? = nil) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: key, dedupKey: dedupKey, sha1: nil, kind: .photo, takenAt: .distantPast, contentVersion: 1,
      durationMs: nil, isFavorite: false, trashedAt: trashedAt, width: nil, height: nil)
  }
}
