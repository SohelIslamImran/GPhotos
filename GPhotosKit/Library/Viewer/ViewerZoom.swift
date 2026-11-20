import SwiftUI

/// The zoom between a grid cell and the viewer, as Photos does it: only the photo moves.
/// Opening, the cell's photo (cropped as in the grid) grows into the whole photo while the
/// viewer's background and controls fade in over the grid; closing, it shrinks back into
/// the cell of the photo showing, from wherever a pull down left it.
///
/// The viewer is presented without an animation over a clear background and the photo is
/// drawn here, in the viewer's own coordinates, so nothing depends on the system's zoom
/// transition (which shrinks the whole screen as a card and can lose its source view).
@MainActor
@Observable
public final class ViewerZoom {
  @ObservationIgnored public let proxy = PhotoGridProxy()

  /// The photo on its way between the grid and the viewer, in window coordinates.
  struct Flight: Equatable {
    var frame: CGRect
    var image: CGImage?
    var opacity: Double
  }

  private(set) var flight: Flight?
  /// 0 over the grid, 1 with the viewer fully up: the viewer's background and controls.
  private(set) var progress: Double = 0
  /// The viewer's pages stay hidden while the photo is flying.
  private(set) var hidesPages = true
  /// How far the photo is pulled down, in points, on the way to closing.
  var pull: CGFloat = 0
  /// Where the pulled photo is in the window, moved and shrunk with the finger.
  @ObservationIgnored var pulledFrame: CGRect?

  @ObservationIgnored private var showing: (index: Int, id: String)?
  @ObservationIgnored private var screen: CGRect = .zero
  @ObservationIgnored private var isClosing = false
  @ObservationIgnored var dismiss: () -> Void = {}

  /// The open item's date and details (Mac), which the grid's screen shows as its title
  /// while the viewer is up: a title set inside the viewer doesn't reach the window.
  var viewerTitle: (title: String, subtitle: String)?

  public init() {}

  /// Critically damped, a little quicker to open than to close, as in Photos.
  private static let opening = Animation.spring(duration: 0.32, bounce: 0)
  private static let closing = Animation.spring(duration: 0.36, bounce: 0)

  /// Before presenting: the photo starts on the tapped cell, which is left empty.
  func prepare(index: Int, id: String) {
    showing = (index, id)
    isClosing = false
    progress = 0
    pull = 0
    pulledFrame = nil
    hidesPages = true
    let image = ThumbnailPipeline.shared.placeholder(for: ThumbnailKey(id: id, bucket: .huge))
    flight = proxy.windowFrame(of: index).map { Flight(frame: $0, image: image, opacity: 1) }
  }

  /// Opens the viewer at `index` of `source`: `present` shows it, without an animation.
  func open(_ index: Int, in source: any PhotoGridDataSource, present: () -> Void) {
    #if os(iOS)
      prepare(index: index, id: source.itemID(at: index))
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction, present)
    #else
      withAnimation(.smooth, present)
    #endif
  }

  /// While the viewer is up: the photo it shows, which it closes into.
  func viewerShows(index: Int, id: String) { showing = (index, id) }

  /// Once the viewer is on screen: the photo grows to fill it. It starts a moment later,
  /// once the viewer has been drawn at the start, so its background and controls fade in
  /// rather than appearing at their end.
  func didAppear(in screen: CGRect, reduceMotion: Bool) {
    self.screen = screen
    DispatchQueue.main.async { self.startOpening(reduceMotion: reduceMotion) }
  }

  /// The area the pages fit their photo in moved (rotation, an iPad window resized).
  func screenChanged(to screen: CGRect) { self.screen = screen }

  private func startOpening(reduceMotion: Bool) {
    guard !isClosing else { return }
    // The cell empties as its photo lifts off, not while the viewer is still on its way.
    if flight != nil, let showing { proxy.hide(showing.index) }
    guard !reduceMotion, let showing else {
      flight = nil
      hidesPages = false
      proxy.hide(nil)
      withAnimation(.easeOut(duration: 0.2)) { progress = 1 }
      return
    }
    let preview = Self.uncroppedImage(for: showing.id)
    // A cropped cell can only stand in at its own frame.
    if let preview { flight?.image = preview }
    if flight == nil || preview == nil { hidesPages = false }
    withAnimation(Self.opening, completionCriteria: .removed) {
      if let preview { flight?.frame = fitted(image: preview) } else { flight?.opacity = 0 }
      progress = 1
    } completion: { [weak self] in
      guard let self, !self.isClosing else { return }
      self.hidesPages = false
      self.flight = nil
      self.proxy.hide(nil)
    }
  }

  /// Closes into the cell of the photo showing (scrolled into view first), from where the
  /// photo is now: fitted, or pulled down.
  func close(reduceMotion: Bool) {
    guard !isClosing else { return }
    isClosing = true
    guard !reduceMotion, let showing, let image = Self.uncroppedImage(for: showing.id) else {
      withAnimation(.easeOut(duration: 0.2)) {
        progress = 0
      } completion: { [weak self] in
        self?.finish()
      }
      return
    }
    let start = pulledFrame ?? fitted(image: image).offsetBy(dx: 0, dy: pull)
    let target = proxy.windowFrame(of: showing.index, revealing: true)
    if target != nil { proxy.hide(showing.index) }
    flight = Flight(frame: start, image: image, opacity: 1)
    hidesPages = true
    withAnimation(Self.closing, completionCriteria: .removed) {
      if let target { flight?.frame = target } else { flight?.opacity = 0 }
      progress = 0
    } completion: { [weak self] in
      self?.finish()
    }
  }

  private func finish() {
    dismiss()
    proxy.hide(nil)
    flight = nil
    showing = nil
    pull = 0
    pulledFrame = nil
    hidesPages = true
  }

  /// The whole photo, as the viewer shows it: what the viewer last drew, else the grid's own
  /// thumbnail. PhotoKit's and folder thumbnails keep the photo's shape (only the cell
  /// crops them), as Photos' do, so the photo grows out of its cell; Google's come
  /// cropped square from the server and can't stand in for the whole photo.
  static func uncroppedImage(for id: String) -> CGImage? {
    if let preview = ThumbnailPipeline.shared.viewerPreview(for: id) { return preview }
    guard RemoteThumbnailID(id) == nil else { return nil }
    return ThumbnailPipeline.shared.placeholder(for: ThumbnailKey(id: id, bucket: .huge))
  }

  /// The photo as the viewer fits it: the whole photo, as large as fits the screen.
  private func fitted(image: CGImage) -> CGRect {
    let size = AspectFit.size(for: CGSize(width: image.width, height: image.height), in: screen.size)
    return CGRect(
      x: screen.minX + (screen.width - size.width) / 2, y: screen.minY + (screen.height - size.height) / 2,
      width: size.width, height: size.height)
  }
}

/// The zoom of the viewer a page is in, told how far its photo is pulled down.
extension EnvironmentValues {
  @Entry var viewerZoom: ViewerZoom?
}

extension View {
  /// Presents `MediaViewer` for the item at `index`, opened with `ViewerZoom.open`: on
  /// iPhone it zooms out of and back into the grid's cells, on the Mac it fades.
  func photoViewer(index: Binding<Int?>, source: (any MediaViewerSource)?, zoom: ViewerZoom) -> some View {
    modifier(PhotoViewerPresentation(index: index, source: source, zoom: zoom))
  }

  /// The screen's title, or the open item's while the viewer is up (Mac).
  func gridTitle(_ title: String, subtitle: String, zoom: ViewerZoom) -> some View {
    #if os(macOS)
      navigationTitle(zoom.viewerTitle?.title ?? title).navigationSubtitle(zoom.viewerTitle?.subtitle ?? subtitle)
    #else
      navigationTitle(title)
    #endif
  }
}

private struct PhotoViewerPresentation: ViewModifier {
  @Binding var index: Int?
  let source: (any MediaViewerSource)?
  let zoom: ViewerZoom
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    #if os(iOS)
      content
        .background {
          OverFullScreen(isPresented: index != nil && source != nil) {
            if let source, let index { viewer(source: source, startIndex: index) }
          }
        }
        .onAppear {
          zoom.dismiss = { [$index] in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { $index.wrappedValue = nil }
          }
        }
    #else
      // Over the whole screen, whatever size the content under it takes (an empty state).
      content.frame(maxWidth: .infinity, maxHeight: .infinity).overlay {
        if let index, let source {
          MediaViewer(
            source: source, startIndex: index, onTitleChange: { zoom.viewerTitle = $0 }
          ) {
            withAnimation(.smooth) { self.index = nil }
            // The grid takes the keys again: arrows and Return pick up where it was.
            DispatchQueue.main.async { zoom.proxy.focus() }
          }
          .transition(.opacity)
          .onDisappear { zoom.viewerTitle = nil }
        }
      }
    #endif
  }

  #if os(iOS)
    private func viewer(source: any MediaViewerSource, startIndex: Int) -> some View {
      ZoomingViewer(zoom: zoom, reduceMotion: reduceMotion) {
        MediaViewer(
          source: source, startIndex: startIndex, zoom: zoom,
          onIndexChange: { index in
            zoom.viewerShows(index: index, id: source.itemID(at: index))
          }
        ) {
          zoom.close(reduceMotion: reduceMotion)
        }
      }
    }
  #endif
}

#if os(iOS)
  /// Presents `content` over the whole screen without an animation, keeping what's below
  /// on screen (a full-screen cover takes it away), so the viewer can fade in over it.
  private struct OverFullScreen<Content: View>: UIViewControllerRepresentable {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content

    final class Coordinator {
      var presented: UIHostingController<Content>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
      let coordinator = context.coordinator
      if isPresented {
        if let presented = coordinator.presented {
          presented.rootView = content()
        } else {
          let controller = UIHostingController(rootView: content())
          controller.modalPresentationStyle = .overFullScreen
          controller.view.backgroundColor = .clear
          coordinator.presented = controller
          host.present(controller, animated: false)
        }
      } else if let presented = coordinator.presented {
        coordinator.presented = nil
        presented.dismiss(animated: false)
      }
    }

    static func dismantleUIViewController(_ host: UIViewController, coordinator: Coordinator) {
      coordinator.presented?.dismiss(animated: false)
    }
  }

  /// The viewer with the flying photo over it, in window coordinates.
  private struct ZoomingViewer<Viewer: View>: View {
    let zoom: ViewerZoom
    let reduceMotion: Bool
    @ViewBuilder let viewer: Viewer

    var body: some View {
      viewer
        // The pages fit their photo to the whole screen, so the flight aims there.
        .background {
          GeometryReader { proxy in
            Color.clear
              .onAppear { zoom.didAppear(in: proxy.frame(in: .global), reduceMotion: reduceMotion) }
              .onChange(of: proxy.frame(in: .global)) { _, frame in zoom.screenChanged(to: frame) }
          }
          .ignoresSafeArea()
        }
        .overlay {
          // The photo flies in window coordinates, over the whole screen.
          Color.clear
            .overlay(alignment: .topLeading) { FlyingPhoto(zoom: zoom) }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }
  }

  private struct FlyingPhoto: View {
    let zoom: ViewerZoom

    var body: some View {
      if let flight = zoom.flight {
        Group {
          if let image = flight.image {
            Image(decorative: image, scale: 1).resizable().scaledToFill()
          } else {
            Color(uiColor: .secondarySystemFill)
          }
        }
        .frame(width: flight.frame.width, height: flight.frame.height)
        .clipped()
        .position(x: flight.frame.midX, y: flight.frame.midY)
        .opacity(flight.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
  }
#endif
