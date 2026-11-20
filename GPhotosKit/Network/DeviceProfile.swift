import Foundation

public struct DeviceProfile: Sendable, Equatable {
  public static let metered = DeviceProfile()

  // The upload commit's device model selects metered storage. The protocol
  // version remains the one used by the existing mobile transport.
  public let model = "Pixel 8"
  public let make = "Google"
  public let androidAPIVersion: Int32 = 28
  public let clientVersionCode: Int32 = 49_029_607

  private init() {}

  public func authUserAgent() -> String {
    "GoogleAuth/1.4; gzip"
  }

  public func photosUserAgent(languageCode: String = "en_US") -> String {
    "com.google.android.apps.photos/\(clientVersionCode) (Linux; U; Android 9; \(languageCode); Cronet/127.0.6510.5) (gzip)"
  }
}

public enum GPhotosEndpoints {
  public static let embeddedSetupAuth = URL(string: "https://android.clients.google.com/auth")!
  public static let embeddedSetup = URL(string: "https://accounts.google.com/EmbeddedSetup")!
  public static let auth = URL(string: "https://android.googleapis.com/auth")!
  public static let userInfo = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
  public static let dedup = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/5084965799730810217")!
  public static let uploadToken = URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive")!
  public static let commit = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752")!
  public static let createMediaItems = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/16538846908252377752")!
  public static let createAlbum = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/8386163679468898444")!
  public static let addMediaToAlbum = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/484917746253879292")!

  public static let librarySync = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/18047484249733410717")!
  public static let trashItems = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/17490284929287180316")!
  public static let setFavorite = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/5144645502632292153")!
  public static let setArchived = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/6715446385130606868")!
  public static let setCaption = URL(string: "https://photosdata-pa.googleapis.com/6439526531001121323/1552790390512470739")!
  public static let prepareDownload = URL(
    string:
      "https://photosdata-pa.googleapis.com/$rpc/social.frontend.photos.preparedownloaddata.v1.PhotosPrepareDownloadDataService/PhotosPrepareDownload"
  )!

  /// Thumbnail URL: `=k-sg`, then size, JPEG, content version, no overlay,
  /// and `-c` to crop to exactly that size.
  public static func thumbnail(mediaKey: String, width: Int?, height: Int?, contentVersion: Int?, crop: Bool = false) -> URL {
    var url = "https://ap2.googleusercontent.com/gpa/\(mediaKey)=k-sg"
    if let width { url += "-w\(width)" }
    if let height { url += "-h\(height)" }
    url += "-rj"
    if let contentVersion, contentVersion > 0 { url += "-iv\(contentVersion)" }
    url += "-no"
    if crop { url += "-c" }
    return URL(string: url)!
  }

  /// HLS stream manifest URL.
  public static func streamManifest(mediaKey: String, contentVersion: Int?) -> URL {
    var url = "https://lh3.googleusercontent.com/p/\(mediaKey)%3Dmm%2Chls-vm"
    if let contentVersion, contentVersion > 0 { url += "-iv\(contentVersion)" }
    return URL(string: url)!
  }

  public static let commitHeader173412678 = "CgcIAhClARgC"
  public static let commitHeader174067345 = "CgIIAg=="
}
