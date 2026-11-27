import CoreGraphics
import Foundation

/// Square-cell grid geometry. Pure arithmetic, so any index's frame and the indices in any
/// rect are O(1) and a 100k-item library costs nothing to lay out.
public struct PhotoGridLayout: Equatable, Sendable {
  public var columns: Int
  public var spacing: CGFloat
  public var width: CGFloat
  public var itemCount: Int
  public var insets: PhotoGridInsets
  /// Cells round down to whole pixels of this scale, so their edges stay crisp.
  public var pixelScale: CGFloat
  /// Older items still to load above these. Their share of the first row is left empty,
  /// so the newest cells keep their columns when those items arrive.
  public var itemsToCome: Int

  public init(
    columns: Int, spacing: CGFloat = 2, width: CGFloat, itemCount: Int, insets: PhotoGridInsets = .zero,
    pixelScale: CGFloat = 1, itemsToCome: Int = 0
  ) {
    self.pixelScale = max(1, pixelScale)
    self.columns = max(1, columns)
    self.spacing = max(0, spacing)
    self.width = max(0, width)
    self.itemCount = max(0, itemCount)
    self.insets = insets
    self.itemsToCome = max(0, itemsToCome)
  }

  public var itemSide: CGFloat {
    let available = width - insets.left - insets.right - spacing * CGFloat(columns - 1)
    return max(1, (available / CGFloat(columns) * pixelScale).rounded(.down) / pixelScale)
  }

  public var rowCount: Int {
    guard itemCount > 0 else { return 0 }
    let cells = itemCount + leadingEmptyCells
    return cells / columns + (cells % columns == 0 ? 0 : 1)
  }

  private var leadingEmptyCells: Int { itemsToCome % columns }

  private var rowPitch: CGFloat { itemSide + spacing }

  /// Spare width from rounding cells down is spread over the gaps so rows stay flush.
  private var columnPitch: CGFloat {
    guard columns > 1 else { return 0 }
    return (width - insets.left - insets.right - itemSide) / CGFloat(columns - 1)
  }

  public var contentHeight: CGFloat {
    guard rowCount > 0 else { return insets.top + insets.bottom }
    return insets.top + CGFloat(rowCount) * rowPitch - spacing + insets.bottom
  }

  public func frame(at index: Int) -> CGRect {
    let cell = UInt(max(0, index)) + UInt(leadingEmptyCells)
    let row = cell / UInt(columns)
    let column = cell % UInt(columns)
    return CGRect(
      x: insets.left + CGFloat(column) * columnPitch, y: insets.top + CGFloat(row) * rowPitch,
      width: itemSide, height: itemSide)
  }

  /// Every index whose cell intersects `rect`.
  public func indices(in rect: CGRect) -> Range<Int> {
    guard itemCount > 0, !rect.isInfinite, rect.height > 0, rect.height.isFinite,
      rect.minY.isFinite, rect.maxY.isFinite, rowPitch.isFinite, rowPitch > 0
    else { return 0..<0 }
    let first = ((rect.minY - insets.top) / rowPitch).rounded(.down)
    let last = ((rect.maxY - insets.top) / rowPitch).rounded(.down)
    guard !first.isNaN, !last.isNaN, last >= 0, first < CGFloat(rowCount) else { return 0..<0 }
    // AppKit can supply enormous visible bounds while a window is changing layout.
    // Clamp before converting: Int(-infinity) and out-of-range finite values trap.
    let firstRow = first <= 0 ? 0 : Int(first)
    let lastRow = last >= CGFloat(rowCount - 1) ? rowCount - 1 : Int(last)
    guard lastRow >= firstRow else { return 0..<0 }
    let lower = max(0, firstRow * columns - leadingEmptyCells)
    let upper = lastRow == rowCount - 1 ? itemCount : (lastRow + 1) * columns - leadingEmptyCells
    return lower..<upper
  }

  public func index(at point: CGPoint) -> Int? {
    guard itemCount > 0, point.x.isFinite, point.y.isFinite,
      point.y >= insets.top, point.x >= insets.left, rowPitch.isFinite, rowPitch > 0
    else { return nil }
    let rowValue = ((point.y - insets.top) / rowPitch).rounded(.down)
    let columnValue = columns > 1 ? ((point.x - insets.left) / columnPitch).rounded(.down) : 0
    guard rowValue >= 0, rowValue < CGFloat(rowCount), columnValue >= 0, columnValue < CGFloat(columns) else { return nil }
    let row = Int(rowValue)
    let column = Int(columnValue)
    let (index, overflow) = (row * columns - leadingEmptyCells).addingReportingOverflow(column)
    guard !overflow, index >= 0, index < itemCount, frame(at: index).contains(point) else { return nil }
    return index
  }

  /// The content offset that keeps `index` at the same height on screen after a column
  /// change, so pinching zooms around what is under the fingers.
  public func offsetKeeping(index: Int, atViewportY viewportY: CGFloat) -> CGFloat {
    max(0, frame(at: index).midY - viewportY)
  }
}

public struct PhotoGridInsets: Equatable, Sendable {
  public var top: CGFloat
  public var left: CGFloat
  public var bottom: CGFloat
  public var right: CGFloat

  public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
    self.top = top
    self.left = left
    self.bottom = bottom
    self.right = right
  }

  public static let zero = PhotoGridInsets()
}

/// Thumbnail sizes are rounded up to a few buckets so every zoom level shares cache
/// entries and a smaller bucket can stand in while a larger one loads.
public enum ThumbnailBucket: Int, CaseIterable, Comparable, Sendable {
  case tiny = 96
  case small = 192
  case medium = 320
  case large = 512
  case huge = 800

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  public static func forPixelSide(_ side: CGFloat) -> ThumbnailBucket {
    allCases.first { CGFloat($0.rawValue) >= side } ?? .huge
  }

  public var pixelSize: CGSize { CGSize(width: rawValue, height: rawValue) }
}
