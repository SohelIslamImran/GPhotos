import Foundation
import Testing
import WebKit

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

  @Test func signInStaysOnGoogleHosts() {
    for host in [
      "accounts.google.com", "photos.google.com", "google.com", "accounts.youtube.com", "www.google.com.my",
      "www.google.co.uk", "google.de",
    ] {
      #expect(GooglePhotosWebSession.isGoogleSignInHost(host), "\(host)")
    }
    for host in [
      "google.abc.io", "google.com.evil.io", "evilgoogle.com", "google.com.evil", "youtube.com", "www.youtube.com",
      "accounts.google.com.attacker.net", "google",
    ] {
      #expect(!GooglePhotosWebSession.isGoogleSignInHost(host), "\(host)")
    }
  }

  @Test func identifiesAsSafari() {
    #expect(GooglePhotosWebSession.safariApplicationName.hasPrefix("Version/"))
    #expect(GooglePhotosWebSession.safariApplicationName.contains("Safari/"))
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

  @Test @MainActor func waitsForPhotosAccountDataAndRequiresAMatch() async throws {
    let session = GooglePhotosWebSession(accountEmail: "person@example.com")
    let page = session.makePage(store: .nonPersistent())
    let request = URLRequest(url: GooglePhotosWebSession.libraryURL)
    let html = """
      <script>
        let reads = 0;
        Object.defineProperty(window, 'WIZ_global_data', {
          get() { if (++reads > 1) return { SNlM0e: 'test', oPEP7c: 'Person@example.com' }; }
        });
      </script>
      """
    for try await event in page.load(simulatedRequest: request, responseHTML: html) {
      if event == .finished { break }
    }
    try await session.verifyAccount(on: page, waitingUpTo: .seconds(2))
    let other = GooglePhotosWebSession(accountEmail: "different@example.com")
    await #expect(throws: GooglePhotosWebError.wrongAccount) {
      try await other.verifyAccount(on: page)
    }
  }

  @Test @MainActor func verifiedCookiesAreAvailableToTheNextSession() async throws {
    let email = "\(UUID())@example.test"
    let session = GooglePhotosWebSession(accountEmail: email)
    let store = WKWebsiteDataStore.nonPersistent()
    let cookie = try #require(
      HTTPCookie(properties: [
        .name: "SessionFixture", .value: "fixture", .domain: "photos.google.com", .path: "/", .discard: "TRUE",
      ]))
    await store.httpCookieStore.setCookie(cookie)
    let page = session.makePage(store: store)
    let request = URLRequest(url: GooglePhotosWebSession.libraryURL)
    let html = "<script>window.WIZ_global_data = { SNlM0e: 'test', oPEP7c: '\(email)' };</script>"
    for try await event in page.load(simulatedRequest: request, responseHTML: html) {
      if event == .finished { break }
    }
    do {
      try await session.saveSignIn(from: store, page: page)
      let next = try await GooglePhotosWebSession(accountEmail: email).makeSignedInDataStore()
      #expect(!next.isPersistent)
      let restored = await next.httpCookieStore.allCookies()
      #expect(restored.contains { $0.name == cookie.name && $0.value == cookie.value && $0.isSessionOnly })
    } catch {
      await GooglePhotosWebSession.deleteWebData(forAccountEmail: email)
      throw error
    }
    await GooglePhotosWebSession.deleteWebData(forAccountEmail: email)
    await #expect(throws: GooglePhotosWebError.signInRequired) {
      try await session.makeSignedInDataStore()
    }
  }

  @Test @MainActor func moveOutUsesTheSelectedKeyFromTheReauthenticatedFolder() async throws {
    let session = GooglePhotosWebSession(accountEmail: "locked@example.test")
    let page = session.makePage(store: .nonPersistent())
    let html = #"""
      <script>
        window.WIZ_global_data = {
          SNlM0e: "token", oPEP7c: "locked@example.test", eptZe: "/_/PhotosUi/",
          FdrFJe: "session", cfb2h: "build", Dbw5Ud: "reauth+token"
        };
        const calls = [];
        window.fetch = async (url, options) => {
          const query = new URL(url).searchParams;
          const rpc = query.get("rpcids");
          const payload = JSON.parse(new URLSearchParams(options.body).get("f.req"))[0][0];
          if (query.get("source-path") !== "/lockedfolder" || query.get("rapt") !== "reauth+token" ||
              payload[0] !== rpc || options.cache !== "no-store") throw Error("wrong request");
          calls.push([rpc, JSON.parse(payload[1])]);
          const results = [
            ["next", [["other", null, null, "other-key"]]],
            [null, [["selected", null, null, "selected-key"]]],
            []
          ];
          return new Response(JSON.stringify([["wrb.fr", rpc, JSON.stringify(results[calls.length - 1])]]));
        };
      </script>
      """#
    let request = URLRequest(url: GooglePhotosWebSession.lockedFolderURL)
    for try await event in page.load(simulatedRequest: request, responseHTML: html) {
      if event == .finished { break }
    }
    #expect(try await session.moveOutOfLockedFolder(mediaKey: "selected", on: page))
    let calls = try await page.callJavaScript("return JSON.stringify(calls);", contentWorld: .page) as? String
    #expect(calls == #"[["nMFwOc",[null]],["nMFwOc",["next"]],["Pp2Xxe",[["selected-key"]]]]"#)
  }

  private func item(_ key: String, dedupKey: String = "dedup", trashedAt: Date? = nil) -> RemoteItemSummary {
    RemoteItemSummary(
      mediaKey: key, dedupKey: dedupKey, sha1: nil, kind: .photo, takenAt: .distantPast, contentVersion: 1,
      durationMs: nil, isFavorite: false, trashedAt: trashedAt, width: nil, height: nil)
  }
}
