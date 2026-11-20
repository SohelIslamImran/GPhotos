import ImageIO
import MapKit
import Photos
import SwiftUI

/// What the info panel shows beyond `PHAsset`'s own properties. Read off the main actor;
/// nothing is downloaded for it.
struct AssetDetails: Sendable, Equatable {
  var filename: String?
  var fileSize: Int64?
  var typeName: String?
  var camera: String?
  var lens: String?
  var exposure: [String] = []
  var albums: [String] = []

  static func load(for asset: PHAsset) async -> AssetDetails {
    var details = AssetDetails()
    let resources = PHAssetResource.assetResources(for: asset)
    let primaryTypes: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
    if let resource = primaryTypes.lazy.compactMap({ type in resources.first { $0.type == type } }).first {
      details.filename = SharedAsset.filename(of: resource)
      details.typeName = resource.contentType.localizedDescription
      details.fileSize = resource.dataSize.map(Int64.init)
    }
    let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
    albums.enumerateObjects { album, _, _ in
      if let title = album.localizedTitle { details.albums.append(title) }
    }
    if asset.mediaType == .image, let resource = resources.first(where: { $0.type == .photo }),
      let properties = await imageProperties(of: resource)
    {
      details.apply(properties)
    }
    return details
  }

  /// Image metadata from the start of the original, only when it's already on this
  /// device. Metadata sits at the front of HEIC and JPEG files, so the read stops early
  /// instead of loading the whole photo.
  private static func imageProperties(of resource: PHAssetResource) async -> [CFString: Any]? {
    final class Prefix: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
      var requestID: PHAssetResourceDataRequestID?
    }
    let prefix = Prefix()
    let limit = 512 << 10
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = false
    let manager = PHAssetResourceManager.default()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let id = manager.requestData(
        for: resource, options: options,
        dataReceivedHandler: { chunk in
          let full = prefix.lock.withLock {
            prefix.data.append(chunk)
            return prefix.data.count >= limit ? prefix.requestID : nil
          }
          if let full { manager.cancelDataRequest(full) }
        },
        completionHandler: { _ in continuation.resume() })
      prefix.lock.withLock { prefix.requestID = id }
    }
    let data = prefix.lock.withLock { prefix.data }
    guard
      !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return nil }
    return properties
  }

  mutating func apply(_ properties: [CFString: Any]) {
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
    let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
    if let model {
      // Apple and others repeat the make in the model ("Apple iPhone 17 Pro").
      camera = make.map { model.localizedCaseInsensitiveContains($0) ? model : "\($0) \(model)" } ?? model
    }
    lens = exif[kCGImagePropertyExifLensModel] as? String
    var exposure: [String] = []
    if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { exposure.append("ISO \(iso)") }
    if let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
      exposure.append("\(focal) mm")
    } else if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
      exposure.append("\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm")
    }
    if let value = exif[kCGImagePropertyExifExposureBiasValue] as? Double, value != 0 {
      exposure.append("\(value.formatted(.number.precision(.fractionLength(0...1))).replacingOccurrences(of: "-", with: "−")) ev")
    }
    if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
      exposure.append("ƒ\(aperture.formatted(.number.precision(.fractionLength(0...1))))")
    }
    if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
      exposure.append(time >= 1 ? "\(time.formatted(.number.precision(.fractionLength(0...1)))) s" : "1/\(Int((1 / time).rounded())) s")
    }
    self.exposure = exposure
  }
}

/// The info panel for one item, in the style of Photos' info pane.
struct PhotoInfoView: View {
  let asset: PHAsset
  let backup: PhotoGridBadges.Backup?
  @State private var details = AssetDetails()
  @State private var place: String?

  var body: some View {
    Form {
      Section {
        if let date = asset.creationDate {
          LabeledContent("Date", value: date.formatted(date: .complete, time: .omitted))
          LabeledContent("Time", value: date.formatted(date: .omitted, time: .shortened))
        }
        if let filename = details.filename { LabeledContent("Name", value: filename) }
      }
      Section {
        if let camera = details.camera { LabeledContent("Camera", value: camera) }
        if let lens = details.lens { Text(lens).font(.callout).foregroundStyle(.secondary) }
        LabeledContent("Size", value: sizeDescription)
        if asset.mediaType == .video {
          LabeledContent("Length", value: Duration.seconds(asset.duration).formatted(.time(pattern: .minuteSecond)))
        }
        if !details.exposure.isEmpty {
          Text(details.exposure.joined(separator: "  ·  ")).font(.callout.monospacedDigit())
        }
      }
      Section("Backup") {
        Label(backupTitle, systemImage: backupSymbol)
      }
      if !details.albums.isEmpty {
        Section("Albums") {
          ForEach(details.albums, id: \.self) { Label($0, systemImage: "rectangle.stack") }
        }
      }
      if let location = asset.location {
        Section("Location") {
          Map(
            initialPosition: .region(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000))
          ) {
            Marker(place ?? "", coordinate: location.coordinate)
          }
          .frame(height: 180)
          .clipShape(.rect(cornerRadius: 12))
          .listRowInsets(EdgeInsets())
          if let place { Text(place) }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: asset.localIdentifier) {
      let asset = asset
      details = await Task.detached(priority: .userInitiated) { await AssetDetails.load(for: asset) }.value
      await loadPlace()
    }
  }

  private var sizeDescription: String {
    var parts = ["\(asset.pixelWidth) × \(asset.pixelHeight)"]
    let megapixels = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000
    if asset.mediaType == .image, megapixels >= 1 {
      parts.append("\(megapixels.formatted(.number.precision(.fractionLength(0)))) MP")
    }
    if let size = details.fileSize { parts.append(size.formatted(.byteCount(style: .file))) }
    if let type = details.typeName { parts.append(type) }
    return parts.joined(separator: " · ")
  }

  private var backupTitle: String {
    switch backup {
    case .backedUp: String(localized: "Backed up to Google Photos")
    case .pending: String(localized: "Waiting to back up")
    case .failed: String(localized: "Backup failed")
    case .cloudOnly: String(localized: "In Google Photos only")
    case nil: String(localized: "Not backed up")
    }
  }

  private var backupSymbol: String {
    switch backup {
    case .backedUp: "checkmark.icloud"
    case .pending: "icloud.and.arrow.up"
    case .failed: "exclamationmark.icloud"
    case .cloudOnly: "cloud"
    case nil: "icloud.slash"
    }
  }

  private func loadPlace() async {
    guard let location = asset.location, let request = MKReverseGeocodingRequest(location: location) else { return }
    let item = try? await request.mapItems.first
    place = item?.addressRepresentations?.cityWithContext ?? item?.address?.shortAddress
  }
}
