#if DEBUG
  import GPhotosKit
  import Photos
  import UIKit

  /// Review hooks for a device with a real library; compiled out of Release.
  enum DebugHooks {
    nonisolated static func testImages(count: Int, size: CGSize, large: Bool, stamp: String) -> [UIImage] {
      (0..<count).map { index in
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
          UIColor.systemTeal.setFill()
          context.fill(CGRect(origin: .zero, size: size))
          if large {
            // Noise doesn't compress, so the file is a few megabytes, like a camera photo.
            for _ in 0..<15_000 {
              UIColor(hue: .random(in: 0...1), saturation: 0.6, brightness: .random(in: 0.3...1), alpha: 1).setFill()
              context.fill(CGRect(x: .random(in: 0..<size.width), y: .random(in: 0..<size.height), width: 24, height: 24))
            }
          }
          let text = "GPhotos background test \(index + 1)\n\(stamp)" as NSString
          text.draw(
            in: CGRect(x: 60, y: size.height / 2 - 150, width: size.width - 120, height: 300),
            withAttributes: [.font: UIFont.boldSystemFont(ofSize: size.width / 18), .foregroundColor: UIColor.white])
        }
      }
    }

    /// The background-upload log is in the App Group, which tools can't read from a device;
    /// a copy in the app's own Documents can be.
    static func copyBackgroundLog() {
      let source = BackgroundUploadLog.fileURL
      let target = URL.documentsDirectory.appendingPathComponent("background-upload.log")
      try? FileManager.default.removeItem(at: target)
      try? FileManager.default.copyItem(at: source, to: target)
    }

    /// `-UIAddTestPhoto YES` saves a generated image to the library, so a background upload
    /// can be tested without the camera.
    static func addTestPhotoIfAsked() async {
      guard UserDefaults.standard.bool(forKey: "UIAddTestPhoto") else { return }
      let stamp = Date().formatted(date: .abbreviated, time: .standard)
      // `-UITestPhotoCount N` with `-UITestPhotoLarge YES` makes a batch long enough to watch.
      let count = max(1, UserDefaults.standard.integer(forKey: "UITestPhotoCount"))
      let large = UserDefaults.standard.bool(forKey: "UITestPhotoLarge")
      let size = large ? CGSize(width: 4032, height: 3024) : CGSize(width: 1200, height: 900)
      let images = await Task.detached(priority: .userInitiated) {
        Self.testImages(count: count, size: size, large: large, stamp: stamp)
      }.value
      do {
        try await PHPhotoLibrary.shared().performChanges {
          for image in images { PHAssetChangeRequest.creationRequestForAsset(from: image) }
        }
        BackgroundUploadLog.write("debug: added \(count) test photo(s) \(stamp)")
        // `-UIQuitAfterTestPhoto YES` leaves it to the photo upload extension, as when the
        // app is swiped away right after a photo is taken.
        if UserDefaults.standard.bool(forKey: "UIQuitAfterTestPhoto") { exit(0) }
      } catch {
        BackgroundUploadLog.write("debug: couldn't add a test photo: \(error)")
      }
    }
  }
#endif
