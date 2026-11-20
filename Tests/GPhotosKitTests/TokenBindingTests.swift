import CryptoKit
import Foundation
import Testing

@testable import GPhotosKit

@Suite("Token Binding and Protocol Alignment")
struct TokenBindingTests {

  private func makeTestAlias(signingKey: P256.Signing.PrivateKey, padding: Bool = false) -> (alias: String, issuer: String) {
    let pkcs8 = signingKey.derRepresentation
    let spki = signingKey.publicKey.derRepresentation

    var writer = ProtobufWriter()
    writer.writeBytes(fieldNumber: 1, pkcs8)
    writer.writeBytes(fieldNumber: 2, spki)

    let alias = TokenBindingSession.ecdsaAliasPrefix + Base64URL.encode(writer.data, padding: padding)
    let issuer = Base64URL.encode(Data(SHA256.hash(data: spki)), padding: false)
    return (alias, issuer)
  }

  // MARK: - Alias Parsing

  @Test("TokenBindingSession parses valid ECDSA alias round-trip")
  func testAliasParseRoundTrip() throws {
    let originalKey = P256.Signing.PrivateKey()
    let (alias, expectedIssuer) = makeTestAlias(signingKey: originalKey, padding: false)

    let (parsedKey, issuer) = try TokenBindingSession.parseAlias(alias)
    #expect(issuer == expectedIssuer)

    // Test that the parsed key can sign and is verified by original public key
    let message = Data("test-auth-binding".utf8)
    let signature = try parsedKey.signature(for: message)
    #expect(originalKey.publicKey.isValidSignature(signature, for: message))
  }

  @Test("TokenBindingSession parses padded base64url alias")
  func testAliasParseWithPadding() throws {
    let originalKey = P256.Signing.PrivateKey()
    let (alias, expectedIssuer) = makeTestAlias(signingKey: originalKey, padding: true)

    let (_, issuer) = try TokenBindingSession.parseAlias(alias)
    #expect(issuer == expectedIssuer)
  }

  @Test("TokenBindingSession throws on invalid alias format")
  func testAliasParseErrors() {
    #expect(throws: GPhotosError.self) {
      try TokenBindingSession.parseAlias("invalid_prefix:something")
    }

    #expect(throws: GPhotosError.self) {
      try TokenBindingSession.parseAlias(TokenBindingSession.ecdsaAliasPrefix + "!!!not-valid-base64!!!")
    }

    // Missing field 2 (SPKI)
    var writer = ProtobufWriter()
    writer.writeBytes(fieldNumber: 1, Data([1, 2, 3]))
    let incompleteAlias = TokenBindingSession.ecdsaAliasPrefix + Base64URL.encode(writer.data)
    #expect(throws: GPhotosError.self) {
      try TokenBindingSession.parseAlias(incompleteAlias)
    }
  }

  // MARK: - JWT Signature & Claims

  @Test("TokenBindingSession generates assertion JWT with valid claims and signature")
  func testJWTSignatureAndClaims() throws {
    let originalKey = P256.Signing.PrivateKey()
    let (alias, expectedIssuer) = makeTestAlias(signingKey: originalKey)

    let session = TokenBindingSession(keyId: 0x1234_5678)
    let (_, jwt) = try TokenBindingSession.create(alias: alias, session: session)

    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    #expect(parts.count == 3)

    // 1. Header
    guard let headerData = Base64URL.decode(parts[0]),
      let headerJSON = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else {
      Issue.record("Failed to parse JWT header")
      return
    }
    #expect(headerJSON["alg"] as? String == "ES256")
    #expect(headerJSON["typ"] as? String == "JWT")

    // 2. Payload
    guard let payloadData = Base64URL.decode(parts[1]),
      let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
    else {
      Issue.record("Failed to parse JWT payload")
      return
    }
    #expect(payloadJSON["namespace"] as? String == "TokenBinding")
    #expect(payloadJSON["aud"] as? String == "https://accounts.google.com/accountmanager")
    #expect(payloadJSON["iss"] as? String == expectedIssuer)

    let iat = payloadJSON["iat"] as? Int64 ?? 0
    let now = Int64(Date().timeIntervalSince1970)
    #expect(abs(iat - now) < 10)

    guard let ephemeralKey = payloadJSON["ephemeral_key"] as? [String: Any] else {
      Issue.record("Missing ephemeral_key in payload")
      return
    }
    #expect(ephemeralKey["kty"] as? String == "type.googleapis.com/google.crypto.tink.EciesAeadHkdfPublicKey")

    guard let keysetB64 = ephemeralKey["TinkKeysetPublicKeyInfo"] as? String,
      let keysetData = Base64URL.decode(keysetB64)
    else {
      Issue.record("Missing or invalid TinkKeysetPublicKeyInfo")
      return
    }
    #expect(!keysetData.isEmpty)

    // 3. Signature verification
    guard let sigData = Base64URL.decode(parts[2]) else {
      Issue.record("Invalid base64 signature")
      return
    }
    let ecdsaSig = try P256.Signing.ECDSASignature(rawRepresentation: sigData)
    let signingInput = "\(parts[0]).\(parts[1])"
    #expect(originalKey.publicKey.isValidSignature(ecdsaSig, for: Data(signingInput.utf8)))
  }

  // MARK: - Tink ECIES Round Trip

  @Test("TokenBindingSession encrypt and decrypt round trip succeeds")
  func testTinkECIESRoundTrip() throws {
    let session = TokenBindingSession(keyId: 0x42AA_BBCC)
    let plaintextToken = "ya29.a0AfH6SMD-mock-google-photos-bearer-token"

    // Simulate Google auth server encrypting response with the client's ephemeral public key
    let serverEphemeral = P256.KeyAgreement.PrivateKey()
    let serverPoint = serverEphemeral.publicKey.x963Representation  // 65 bytes
    let serverSharedSecret = try serverEphemeral.sharedSecretFromKeyAgreement(with: session.ephemeralPrivateKey.publicKey)
      .withUnsafeBytes { Data($0) }

    let ikm = serverPoint + serverSharedSecret
    let demKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ikm),
      salt: Data(),
      info: Data(),
      outputByteCount: 16
    )

    let box = try AES.GCM.seal(Data(plaintextToken.utf8), using: demKey)
    guard let aesPayload = box.combined else {
      Issue.record("AES-GCM combined payload missing")
      return
    }

    var serverWire = Data([0x01])  // TINK prefix
    serverWire.append(UInt8((session.keyId >> 24) & 0xFF))
    serverWire.append(UInt8((session.keyId >> 16) & 0xFF))
    serverWire.append(UInt8((session.keyId >> 8) & 0xFF))
    serverWire.append(UInt8(session.keyId & 0xFF))
    serverWire.append(serverPoint)
    serverWire.append(aesPayload)

    let encryptedB64 = Base64URL.encode(serverWire)

    // Decrypt on client side
    let decrypted = try session.decryptToken(encryptedB64)
    #expect(decrypted == plaintextToken)

    // Test decryptTokenEncryptedResponse helper
    var parsed: [String: String] = [
      "TokenEncrypted": "1",
      "Auth": encryptedB64,
      "Expiry": "1800000000",
    ]
    try TokenBindingSession.decryptTokenEncryptedResponse(&parsed, session: session)
    #expect(parsed["Auth"] == plaintextToken)
  }

  @Test("decryptTokenEncryptedResponse handles error conditions")
  func testDecryptResponseErrors() {
    let session = TokenBindingSession(keyId: 100)

    // Missing session
    var parsed1 = ["TokenEncrypted": "1", "Auth": "some-token"]
    #expect(throws: GPhotosError.self) {
      try TokenBindingSession.decryptTokenEncryptedResponse(&parsed1, session: nil)
    }

    // Encrypted 'it' token instead of Auth
    var parsed2 = ["TokenEncrypted": "1", "it": "encrypted-it-token"]
    #expect(throws: GPhotosError.self) {
      try TokenBindingSession.decryptTokenEncryptedResponse(&parsed2, session: session)
    }

    // Unencrypted response is untouched
    var parsed3 = ["TokenEncrypted": "0", "Auth": "plain-token"]
    #expect(throws: Never.self) {
      try TokenBindingSession.decryptTokenEncryptedResponse(&parsed3, session: session)
    }
    #expect(parsed3["Auth"] == "plain-token")
  }

  // MARK: - Language Plumbing & Credential Sanitization

  @Test("GoogleAuthService credentialLanguage extracts lang parameter or defaults to en_US")
  func testCredentialLanguage() async throws {
    let service = GoogleAuthService()
    #expect(await service.credentialLanguage() == "en_US")

    try await service.setCredential("androidId=123&lang=ja_JP&Email=test@example.com")
    #expect(await service.credentialLanguage() == "ja_JP")

    try await service.setCredential("androidId=123&Email=test@example.com")
    #expect(await service.credentialLanguage() == "en_US")
  }

  @Test("GoogleAuthService retains token_binding_alias in sanitized credential")
  func testSanitizedCredentialKeepsTokenBindingAlias() throws {
    let raw =
      "Email=test@example.com&androidId=abc&token_binding_alias=auth_account:ecdsa_keypair:xyz&assertion_jwt=oldjwt&it_caveat_types=1"
    let sanitized = try GoogleAuthService.sanitizedCredentialQuery(from: raw)
    let items = FormURLEncoding.decode(sanitized)

    #expect(items.contains { $0.name == "token_binding_alias" })
    #expect(!items.contains { $0.name == "assertion_jwt" })
    #expect(!items.contains { $0.name == "it_caveat_types" })
  }

  // MARK: - Protobuf Divergence Fixes

  @Test("encodeAddMediaToAlbum uses field 7 for timestamp")
  func testAddMediaToAlbumTimestampField7() throws {
    let data = GooglePhotosMessages.encodeAddMediaToAlbum(
      albumMediaKey: "album-key-1",
      mediaKeys: ["media-key-1"],
      device: .metered
    )

    var reader = ProtobufReader(data: data)
    var foundField7 = false
    var foundField8 = false

    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 7 {
        foundField7 = true
        _ = try reader.readInt64()
      } else if field == 8 {
        foundField8 = true
        try reader.skipField(wireType: wireType)
      } else {
        try reader.skipField(wireType: wireType)
      }
    }

    #expect(foundField7, "Timestamp should be encoded as field 7 per AddMediaToAlbum.pb.go")
    #expect(!foundField8, "Field 8 was the old incorrect timestamp field")
  }

  @Test("encodeLivePhotoReconcile uses field 9 with reconcile_type 1 and source_sha1 3")
  func testLivePhotoReconcileProtoFields() throws {
    let req = LivePhotoReconcileRequest(
      videoToken: ScottyFinalizeToken(raw: Data([1, 2, 3])),
      fileName: "test.mov",
      photoSHA1: Data(repeating: 0xBB, count: 20),
      videoSHA1: Data(repeating: 0xAA, count: 20),
      createdAt: Date(timeIntervalSince1970: 1000),
      modifiedAt: Date(timeIntervalSince1970: 1000),
      device: .metered
    )

    let data = try GooglePhotosMessages.encodeLivePhotoReconcile(input: req)
    var reader = ProtobufReader(data: data)

    var foundBlueprint = false
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      if field == 1 && wireType == .lengthDelimited {
        foundBlueprint = true
        let blueprintBytes = try reader.readBytes()
        var bpReader = ProtobufReader(data: blueprintBytes)

        var foundReconcileInfoField9 = false
        var foundOldField23 = false

        while !bpReader.isAtEnd {
          let (bpField, bpWire) = try bpReader.readTag()
          if bpField == 9 && bpWire == .lengthDelimited {
            foundReconcileInfoField9 = true
            let reconcileBytes = try bpReader.readBytes()
            var recReader = ProtobufReader(data: reconcileBytes)
            var reconcileType: Int32?
            var sourceSha1: Data?

            while !recReader.isAtEnd {
              let (recField, recWire) = try recReader.readTag()
              if recField == 2 && recWire == .varint {
                reconcileType = Int32(try recReader.readInt64())
              } else if recField == 3 && recWire == .lengthDelimited {
                sourceSha1 = try recReader.readBytes()
              } else {
                try recReader.skipField(wireType: recWire)
              }
            }

            #expect(reconcileType == 1, "RECONCILE_TYPE_PHODEO is 1 per CreateMediaItems.pb.go")
            #expect(sourceSha1 == req.photoSHA1, "Source SHA1 must be in field 3")
          } else if bpField == 23 {
            foundOldField23 = true
            try bpReader.skipField(wireType: bpWire)
          } else {
            try bpReader.skipField(wireType: bpWire)
          }
        }

        #expect(foundReconcileInfoField9, "ReconcileInfo must be encoded as blueprint field 9")
        #expect(!foundOldField23, "Blueprint field 23 was the old incorrect field")
      } else {
        try reader.skipField(wireType: wireType)
      }
    }
    #expect(foundBlueprint)
  }

  @Test("decodeCreateMediaItemsResponse reads field 3 result_item")
  func testDecodeCreateMediaItemsResponse() throws {
    // Structure: item(1) -> result_item(3) -> media_key(1)
    var resultItemWriter = ProtobufWriter()
    resultItemWriter.writeString(fieldNumber: 1, "expected-media-key-xyz")

    var itemWriter = ProtobufWriter()
    itemWriter.writeBytes(fieldNumber: 3, resultItemWriter.data)

    var rootWriter = ProtobufWriter()
    rootWriter.writeBytes(fieldNumber: 1, itemWriter.data)

    let decodedKey = try GooglePhotosMessages.decodeCreateMediaItemsResponse(rootWriter.data)
    #expect(decodedKey == "expected-media-key-xyz")
  }
}
