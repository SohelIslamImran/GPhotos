import Accelerate
import CoreGraphics
import Foundation
import Vision

/// Runs every on-device analysis for one thumbnail in a single Vision pass: scene labels,
/// text, an image feature print (similar photos), faces with their own prints (People) and
/// the aesthetics score (best shot, clutter).
enum ItemAnalyzer {
  /// Labels below this aren't stored. Vision is unsure of everyday subjects (a mountain
  /// range scores about 0.25 as "mountain"), and search ranks by confidence, so weaker
  /// labels add results at the end instead of pushing better ones down.
  static let minimumLabelConfidence: Float = 0.2

  /// Throws only if every request fails (some aren't available in the simulator or on
  /// older hardware).
  static func analyze(
    _ image: CGImage, includesFeaturePrint: Bool = true, faceImage: (@Sendable () async -> CGImage?)? = nil
  ) async throws -> ItemAnalysis {
    let handler = ImageRequestHandler(image)
    var text = RecognizeTextRequest()
    text.recognitionLevel = .fast
    text.usesLanguageCorrection = true
    let labels: [ClassificationObservation]
    let recognized: [RecognizedTextObservation]
    let faces: [FaceObservation]
    let aesthetics: ImageAestheticsScoresObservation?
    // One combined pass shares the image preparation; if any request is unavailable it
    // fails as a whole, and each runs on its own instead.
    if let all = try? await handler.perform(
      ClassifyImageRequest(), text, DetectFaceRectanglesRequest(), CalculateImageAestheticsScoresRequest())
    {
      (labels, recognized, faces) = (all.0, all.1, all.2)
      aesthetics = all.3
    } else {
      labels = (try? await handler.perform(ClassifyImageRequest())) ?? []
      recognized = (try? await handler.perform(text)) ?? []
      faces = (try? await handler.perform(DetectFaceRectanglesRequest())) ?? []
      aesthetics = try? await handler.perform(CalculateImageAestheticsScoresRequest())
    }
    let print = includesFeaturePrint ? rawFeaturePrint(image) : nil
    guard !labels.isEmpty || !recognized.isEmpty || print != nil || aesthetics != nil else {
      throw CocoaError(.featureUnsupported)
    }

    var analysis = ItemAnalysis()
    analysis.labels =
      labels
      .filter {
        $0.confidence >= minimumLabelConfidence
          && (!$0.hasPrecisionRecallCurve || $0.hasMinimumRecall(0.01, forPrecision: 0.7))
      }
      .sorted { $0.confidence > $1.confidence }
      .map { ($0.identifier, $0.confidence) }
    analysis.text = recognized.map(\.transcript).joined(separator: " ")
    analysis.featurePrint = print
    analysis.aesthetics = aesthetics?.overallScore
    analysis.isUtility = aesthetics?.isUtility ?? false

    if !faces.isEmpty {
      let needsLargerCrop = faces.contains {
        min($0.boundingBox.width * Double(image.width), $0.boundingBox.height * Double(image.height)) < 160
      }
      let larger = needsLargerCrop ? await faceImage?() : nil
      analysis.faces = await analyzeFaces(larger ?? image, detected: larger == nil ? faces : nil)
      analysis.facesIncomplete = needsLargerCrop && larger == nil && faceImage != nil
    }
    return analysis
  }

  /// Faces turned no more than about a third of the way aside, captured well enough to
  /// compare, with their prints. Stricter limits left most candid photos of a person out;
  /// grouping still joins faces only when their prints are close. Pose comes from the Swift
  /// Vision API: the older `VNFaceObservation` has no pitch and only rough yaw steps.
  static func analyzeFaces(_ image: CGImage, detected: [FaceObservation]? = nil) async -> [DetectedFace] {
    let handler = ImageRequestHandler(image)
    var found = detected
    if found == nil { found = try? await handler.perform(DetectFaceRectanglesRequest()) }
    guard let found, !found.isEmpty else { return [] }
    var request = DetectFaceCaptureQualityRequest()
    request.inputFaceObservations = found
    guard let observations = try? await handler.perform(request) else { return [] }
    return observations.compactMap { face -> DetectedFace? in
      // Normalized with the origin at the bottom left, as Core Graphics draws.
      let box = face.boundingBox.cgRect
      let rect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
      let yaw = face.yaw.converted(to: .radians).value
      let pitch = face.pitch.converted(to: .radians).value
      let roll = face.roll.converted(to: .radians).value
      guard let score = face.captureQuality.map({ Double($0.score) }),
        score >= 0.35, abs(yaw) <= 0.6, abs(pitch) <= 0.45,
        box.width * CGFloat(image.width) >= 64, box.height * CGFloat(image.height) >= 64,
        let crop = alignedFace(image, box: box, roll: roll), let print = rawFeaturePrint(crop)
      else { return nil }
      return DetectedFace(rect: rect, featurePrint: print, quality: score * cos(yaw) * cos(pitch))
    }
  }

  private static func alignedFace(_ image: CGImage, box: CGRect, roll: Double) -> CGImage? {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    let side = max(box.width * width, box.height * height) * 1.25
    let center = CGPoint(x: box.midX * width, y: box.midY * height)
    let extent = side * (abs(cos(roll)) + abs(sin(roll))) / 2
    guard center.x >= extent, center.y >= extent, center.x + extent <= width, center.y + extent <= height,
      let context = CGContext(
        data: nil, width: 224, height: 224, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.translateBy(x: 112, y: 112)
    context.scaleBy(x: 224 / side, y: 224 / side)
    // Vision's roll is measured the opposite way to Core Graphics' rotation, so turning by
    // it levels the face.
    context.rotate(by: roll)
    context.translateBy(x: -center.x, y: -center.y)
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    // A consistent, tight crop removes scene/clothing cues. Landmark geometry varies
    // with expression and pose, so it is not treated as extra identity evidence.
    return context.makeImage()
  }

  /// The image's feature print as its raw 32-bit floats. Vision's distance between two
  /// prints is the Euclidean distance between these vectors (checked in the tests), so
  /// they're compared with vDSP instead of decoding observations for every pair.
  static func rawFeaturePrint(_ image: CGImage) -> Data? {
    let request = VNGenerateImageFeaturePrintRequest()
    guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
      let observation = request.results?.first, observation.elementType == .float
    else { return nil }
    return observation.data
  }
}

/// Feature prints held as one contiguous float buffer, compared without allocation.
struct FeatureVectors: Sendable {
  private let values: [Float]
  private let dimension: Int
  /// False for rows whose print was missing or a different size.
  private let valid: [Bool]

  init(_ prints: [Data?]) {
    let dimension = prints.lazy.compactMap { $0 }.first.map { $0.count / MemoryLayout<Float>.size } ?? 0
    var values = [Float](repeating: 0, count: dimension * prints.count)
    var valid = [Bool](repeating: false, count: prints.count)
    values.withUnsafeMutableBytes { buffer in
      for (row, print) in prints.enumerated() {
        guard let print, dimension > 0, print.count == dimension * MemoryLayout<Float>.size else { continue }
        print.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[(row * dimension * 4)..<((row + 1) * dimension * 4)]))
        valid[row] = true
      }
    }
    self.values = values
    self.dimension = dimension
    self.valid = valid
  }

  var count: Int { valid.count }

  /// Euclidean distance between rows, or nil if either has no print.
  func distance(_ a: Int, _ b: Int) -> Double? {
    guard valid[a], valid[b] else { return nil }
    var squared: Float = 0
    values.withUnsafeBufferPointer { buffer in
      let base = buffer.baseAddress!
      vDSP_distancesq(base + a * dimension, 1, base + b * dimension, 1, &squared, vDSP_Length(dimension))
    }
    return Double(squared.squareRoot())
  }
}
