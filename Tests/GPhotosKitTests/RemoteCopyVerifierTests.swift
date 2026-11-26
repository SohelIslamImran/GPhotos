import Foundation
import Testing

@testable import GPhotosKit

@Suite("Remote copy verification")
struct RemoteCopyVerifierTests {
  private actor LookupLog {
    var calls: [(String, Bool)] = []
    func record(_ sha1: Data, _ motion: Bool) { calls.append((sha1.base64EncodedString(), motion)) }
  }

  private static func hash(_ byte: UInt8) -> String { Data(repeating: byte, count: 20).base64EncodedString() }

  private static func record(
    _ id: String, sha1: String?, pairedSHA1: String? = nil, pairedPath: String? = nil
  )
    -> TransferRecord
  {
    TransferRecord(
      id: "a@example.com|\(id)", filename: id, mediaType: "Photo", status: .sent,
      sentAccountEmails: ["a@example.com"], mediaKeysByAccount: ["a@example.com": "key-\(id)"], sha1: sha1,
      pairedSourcePath: pairedPath, pairedSourceSHA1: pairedSHA1)
  }

  @Test("Only items Google Photos still holds are kept, and errors hold items back")
  func keepsOnlyConfirmed() async {
    let present = Self.hash(1)
    let failing = Self.hash(3)
    let verifier = RemoteCopyVerifier { sha1, _ in
      let encoded = sha1.base64EncodedString()
      if encoded == failing { throw URLError(.notConnectedToInternet) }
      return encoded == present ? "media" : nil
    }
    let records = [
      Self.record("kept", sha1: present),
      Self.record("gone", sha1: Self.hash(2)),
      Self.record("error", sha1: failing),
      Self.record("unhashed", sha1: nil),
    ]
    let confirmed = await verifier.confirmed(records, accountEmail: "a@example.com")
    #expect(confirmed.map(\.filename) == ["kept"])
  }

  @Test("A Live Photo needs its still and its motion")
  func livePhotoNeedsBothParts() async {
    let still = Self.hash(1)
    let motion = Self.hash(2)
    let log = LookupLog()
    let verifier = RemoteCopyVerifier { sha1, isMotion in
      await log.record(sha1, isMotion)
      let encoded = sha1.base64EncodedString()
      return (encoded == still && !isMotion) || (encoded == motion && isMotion) ? "media" : nil
    }
    let live = Self.record("live", sha1: still, pairedSHA1: motion)
    let missingMotion = Self.record("missing", sha1: still, pairedSHA1: Self.hash(4))
    let unhashedMotion = Self.record("unhashed", sha1: still, pairedPath: "/tmp/IMG.MOV")
    let confirmed = await verifier.confirmed([live, missingMotion, unhashedMotion], accountEmail: "a@example.com")
    #expect(confirmed.map(\.filename) == ["live"])
    #expect(await log.calls.contains { $0 == (motion, true) })
  }

  @Test("A recent confirmation is reused, an old one is asked again")
  func reusesRecentConfirmations() async {
    let log = LookupLog()
    let verifier = RemoteCopyVerifier(confirmationLifetime: 60) { sha1, isMotion in
      await log.record(sha1, isMotion)
      return "media"
    }
    let records = [Self.record("one", sha1: Self.hash(1))]
    let start = Date()
    _ = await verifier.confirmed(records, accountEmail: "a@example.com", now: start)
    _ = await verifier.confirmed(records, accountEmail: "a@example.com", now: start.addingTimeInterval(30))
    #expect(await log.calls.count == 1)
    _ = await verifier.confirmed(records, accountEmail: "a@example.com", now: start.addingTimeInterval(90))
    #expect(await log.calls.count == 2)
  }

  @Test("A lookup spanning a credential change confirms nothing and cannot seed the cache")
  func discardsChangedCredentialResults() async throws {
    let email = "a@example.com"
    let auth = GoogleAuthService()
    try await auth.setCredential("Email=\(email)")
    let started = OneShotSignal()
    let release = OneShotSignal()
    let log = LookupLog()
    let verifier = RemoteCopyVerifier(auth: auth) { sha1, motion in
      await log.record(sha1, motion)
      if await log.calls.count == 1 {
        started.resume()
        await release.wait()
        return "stale-media"
      }
      return nil
    }
    let records = [Self.record("switched", sha1: Self.hash(9))]
    let wrongAccount = LookupLog()
    let wrongAccountVerifier = RemoteCopyVerifier(auth: auth) { sha1, motion in
      await wrongAccount.record(sha1, motion)
      return "wrong-account-media"
    }
    #expect(await wrongAccountVerifier.confirmed(records, accountEmail: "b@example.com").isEmpty)
    #expect(await wrongAccount.calls.isEmpty)

    let lookup = Task { await verifier.confirmed(records, accountEmail: email) }
    await started.wait()
    // Reinstall even the same email: an email check alone cannot establish which token was used.
    try await auth.setCredential("Email=\(email)&Token=changed")
    release.resume()
    #expect(await lookup.value.isEmpty)
    #expect(await verifier.cachedConfirmationCount == 0)
    #expect(await verifier.confirmed(records, accountEmail: email).isEmpty)
    #expect(await log.calls.count == 2)
  }

}
