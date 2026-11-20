import CryptoKit
import Foundation

public struct TokenBindingSession: Sendable {
  public let keyId: UInt32
  public let ephemeralPrivateKey: P256.KeyAgreement.PrivateKey

  public init(
    keyId: UInt32 = UInt32.random(in: 1...UInt32.max),
    ephemeralPrivateKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()
  ) {
    self.keyId = keyId
    self.ephemeralPrivateKey = ephemeralPrivateKey
  }

  public static let ecdsaAliasPrefix = "auth_account:ecdsa_keypair:"

  public static func parseAlias(_ alias: String) throws -> (signingKey: P256.Signing.PrivateKey, issuer: String) {
    guard alias.hasPrefix(ecdsaAliasPrefix) else {
      let prefix = alias.components(separatedBy: ":").prefix(2).joined(separator: ":")
      throw GPhotosError.invalidCredential("unsupported token binding alias type \"\(prefix)\"")
    }
    let encoded = String(alias.dropFirst(ecdsaAliasPrefix.count))
    guard let raw = Base64URL.decode(encoded) else {
      throw GPhotosError.invalidCredential("failed to decode token binding alias")
    }

    var reader = ProtobufReader(data: raw)
    var pkcs8Data: Data?
    var spkiData: Data?
    while !reader.isAtEnd {
      let (field, wireType) = try reader.readTag()
      switch field {
      case 1 where wireType == .lengthDelimited:
        pkcs8Data = try reader.readBytes()
      case 2 where wireType == .lengthDelimited:
        spkiData = try reader.readBytes()
      default:
        try reader.skipField(wireType: wireType)
      }
    }

    guard let pkcs8 = pkcs8Data, !pkcs8.isEmpty, let spki = spkiData, !spki.isEmpty else {
      throw GPhotosError.invalidCredential("token binding alias is missing private or public key material")
    }

    let signingKey: P256.Signing.PrivateKey
    do {
      signingKey = try P256.Signing.PrivateKey(derRepresentation: pkcs8)
    } catch {
      throw GPhotosError.invalidCredential("failed to parse token binding private key: \(error.localizedDescription)")
    }

    let issuerHash = SHA256.hash(data: spki)
    let issuer = Base64URL.encode(Data(issuerHash), padding: false)

    return (signingKey, issuer)
  }

  public static func buildTinkPublicKeySetProto(keyId: UInt32, publicKey: P256.KeyAgreement.PublicKey) -> Data {
    let uncompressedPoint = publicKey.x963Representation  // 65 bytes: 0x04 || X(32) || Y(32)
    let xCoord = uncompressedPoint.subdata(in: 1..<33)
    let yCoord = uncompressedPoint.subdata(in: 33..<65)

    var writer = ProtobufWriter()
    // Field 1: primary_key_id (varint)
    writer.writeInt64(fieldNumber: 1, Int64(keyId))
    // Field 2: key (repeated message)
    writer.writeMessage(fieldNumber: 2) { keyMsg in
      // Field 1: key_data
      keyMsg.writeMessage(fieldNumber: 1) { keyDataMsg in
        keyDataMsg.writeString(fieldNumber: 1, "type.googleapis.com/google.crypto.tink.EciesAeadHkdfPublicKey")
        // Field 2: value (serialized EciesAeadHkdfPublicKey bytes)
        keyDataMsg.writeMessage(fieldNumber: 2) { eciesMsg in
          // params (field 2)
          eciesMsg.writeMessage(fieldNumber: 2) { paramsMsg in
            // kem_params (field 1)
            paramsMsg.writeMessage(fieldNumber: 1) { kemMsg in
              kemMsg.writeInt32(fieldNumber: 1, 2)  // NIST_P256
              kemMsg.writeInt32(fieldNumber: 2, 3)  // SHA256
            }
            // dem_params (field 2)
            paramsMsg.writeMessage(fieldNumber: 2) { demMsg in
              // aead_dem (field 2)
              demMsg.writeMessage(fieldNumber: 2) { aeadDemMsg in
                aeadDemMsg.writeString(fieldNumber: 1, "type.googleapis.com/google.crypto.tink.AesGcmKey")
                // value: serialized AesGcmKeyFormat (field 2)
                aeadDemMsg.writeMessage(fieldNumber: 2) { gcmFormatMsg in
                  gcmFormatMsg.writeInt32(fieldNumber: 2, 16)  // key_size = 16
                }
                aeadDemMsg.writeInt32(fieldNumber: 3, 3)  // RAW
              }
            }
            // ec_point_format (field 3)
            paramsMsg.writeInt32(fieldNumber: 3, 1)  // UNCOMPRESSED
          }
          // x (field 3)
          eciesMsg.writeBytes(fieldNumber: 3, xCoord)
          // y (field 4)
          eciesMsg.writeBytes(fieldNumber: 4, yCoord)
        }
        // Field 3: key_material_type = ASYMMETRIC_PUBLIC (3)
        keyDataMsg.writeInt32(fieldNumber: 3, 3)
      }
      // Field 2: status = ENABLED (1)
      keyMsg.writeInt32(fieldNumber: 2, 1)
      // Field 3: key_id
      keyMsg.writeInt64(fieldNumber: 3, Int64(keyId))
      // Field 4: output_prefix_type = TINK (1)
      keyMsg.writeInt32(fieldNumber: 4, 1)
    }
    return writer.data
  }

  public static func create(
    alias: String,
    session: TokenBindingSession = TokenBindingSession()
  ) throws -> (session: TokenBindingSession, assertionJWT: String) {
    let (signingKey, issuer) = try parseAlias(alias)
    let keysetProto = buildTinkPublicKeySetProto(keyId: session.keyId, publicKey: session.ephemeralPrivateKey.publicKey)
    let publicKeysetB64 = Base64URL.encode(keysetProto, padding: false)

    let headerJSON = "{\"alg\":\"ES256\",\"typ\":\"JWT\"}"
    let b64Header = Base64URL.encode(Data(headerJSON.utf8), padding: false)

    let now = Int64(Date().timeIntervalSince1970)
    // Keys in sorted order, byte for byte what the reference client's JSON encoder
    // (Go, maps) produces.
    let payloadJSON =
      "{\"aud\":\"https://accounts.google.com/accountmanager\",\"ephemeral_key\":{\"TinkKeysetPublicKeyInfo\":\"\(publicKeysetB64)\",\"kty\":\"type.googleapis.com/google.crypto.tink.EciesAeadHkdfPublicKey\"},\"iat\":\(now),\"iss\":\"\(issuer)\",\"namespace\":\"TokenBinding\"}"
    let b64Payload = Base64URL.encode(Data(payloadJSON.utf8), padding: false)

    let signingInput = "\(b64Header).\(b64Payload)"
    let rawSig = try signingKey.signature(for: Data(signingInput.utf8)).rawRepresentation
    let b64Signature = Base64URL.encode(rawSig, padding: false)

    let assertionJWT = "\(signingInput).\(b64Signature)"
    return (session, assertionJWT)
  }

  public func decryptToken(_ encryptedToken: String) throws -> String {
    guard let ciphertext = Base64URL.decode(encryptedToken) else {
      throw GPhotosError.tokenBindingFailed("failed to decode encrypted token")
    }

    // Tink ECIES format:
    // 1 byte: 0x01 (TINK prefix)
    // 4 bytes: keyId (big-endian)
    // 65 bytes: uncompressed public key point (0x04 || X || Y)
    // rest: AES-GCM payload (12-byte IV || ciphertext || 16-byte tag)
    guard ciphertext.count >= (1 + 4 + 65 + 12 + 16) else {
      throw GPhotosError.tokenBindingFailed("ciphertext too short")
    }
    guard ciphertext[0] == 0x01 else {
      throw GPhotosError.tokenBindingFailed("unsupported Tink prefix byte: \(ciphertext[0])")
    }

    let recvKeyId =
      (UInt32(ciphertext[1]) << 24)
      | (UInt32(ciphertext[2]) << 16)
      | (UInt32(ciphertext[3]) << 8)
      | UInt32(ciphertext[4])
    guard recvKeyId == keyId else {
      throw GPhotosError.tokenBindingFailed("key ID mismatch: received \(recvKeyId), expected \(keyId)")
    }

    let theirPoint = ciphertext.subdata(in: 5..<70)
    let aesPayload = ciphertext.subdata(in: 70..<ciphertext.count)

    let theirPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: theirPoint)
    let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: theirPublicKey)
    let rawSharedSecret = sharedSecret.withUnsafeBytes { Data($0) }

    let ikm = theirPoint + rawSharedSecret
    let demKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ikm),
      salt: Data(),
      info: Data(),
      outputByteCount: 16
    )

    let sealedBox = try AES.GCM.SealedBox(combined: aesPayload)
    let plaintext = try AES.GCM.open(sealedBox, using: demKey)

    guard let decryptedString = String(data: plaintext, encoding: .utf8) else {
      throw GPhotosError.tokenBindingFailed("failed to decode decrypted token as UTF-8")
    }
    return decryptedString
  }

  public static func decryptTokenEncryptedResponse(
    _ parsed: inout [String: String],
    session: TokenBindingSession?
  ) throws {
    guard parsed["TokenEncrypted"] == "1" else {
      return
    }
    guard let session else {
      throw GPhotosError.tokenBindingFailed(
        "auth response returned TokenEncrypted=1 but credential has no token_binding_alias")
    }

    guard let encryptedToken = parsed["Auth"], !encryptedToken.isEmpty else {
      if parsed["it"] != nil {
        throw GPhotosError.tokenBindingFailed(
          "auth response returned encrypted it token; remove it_caveat_types to request encrypted Auth")
      }
      throw GPhotosError.tokenBindingFailed(
        "auth response returned TokenEncrypted=1 but no encrypted Auth field was present")
    }

    let plaintext = try session.decryptToken(encryptedToken)
    parsed["Auth"] = plaintext
  }
}

public enum Base64URL {
  public static func encode(_ data: Data, padding: Bool = false) -> String {
    var str =
      data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
    if !padding {
      str = str.replacingOccurrences(of: "=", with: "")
    }
    return str
  }

  public static func decode(_ string: String) -> Data? {
    var base64 =
      string
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder > 0 {
      base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
  }
}
