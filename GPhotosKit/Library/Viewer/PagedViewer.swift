import SwiftUI

/// Horizontal paging over any number of pages that keeps only the current page and its
/// neighbours alive, so opening item 80,000 of 100,000 costs the same as item 0. SwiftUI's
/// lazy stacks have to account for every page before it to scroll that far.
struct PagedViewer<Page: View>: View {
  let count: Int
  @Binding var index: Int?
  /// The position in items while the user swipes (2.4 is 40% from the third page to the
  /// fourth), for things that move with the finger. iPhone only.
  var onSwipe: ((CGFloat) -> Void)?
  /// A finger is on the pages. iPhone only.
  var onTouch: (() -> Void)?
  /// Which item a page shows: when the item at the current page changes (it was deleted),
  /// the next one slides in, as in Photos. iPhone only.
  var pageID: ((Int) -> String)?
  /// Where an item is now (its id, and where it was), when the library changed under it:
  /// the viewer stays on it instead of on its old position. iPhone only.
  var locate: ((String, Int) -> Int?)?
  let page: (Int) -> Page

  var body: some View {
    #if os(iOS)
      PagedViewerRepresentable(
        count: count, index: $index, onSwipe: onSwipe, onTouch: onTouch, pageID: pageID, locate: locate,
        page: page)
    #else
      PagedViewerRepresentable(count: count, index: $index, page: page)
    #endif
  }
}

#if os(iOS)
  import UIKit

  final class PageHost: UIHostingController<AnyView> {
    var index: Int
    var itemID: String?

    init(index: Int, itemID: String?, content: AnyView) {
      self.index = index
      self.itemID = itemID
      super.init(rootView: content)
      view.backgroundColor = .clear
      // Photos fit the whole screen and are centered on it, as in Photos; the safe area would
      // push them down by the difference between its top and bottom.
      safeAreaRegions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  }

  struct PagedViewerRepresentable<Page: View>: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int?
    let onSwipe: ((CGFloat) -> Void)?
    let onTouch: (() -> Void)?
    let pageID: ((Int) -> String)?
    let locate: ((String, Int) -> Int?)?
    let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIPageViewController {
      let controller = UIPageViewController(
        transitionStyle: .scroll, navigationOrientation: .horizontal, options: [.interPageSpacing: 12])
      controller.dataSource = context.coordinator
      controller.delegate = context.coordinator
      controller.view.backgroundColor = .clear
      // The pager's own scroll view; its offset during a swipe is the finger's progress.
      if let scrollView = controller.view.subviews.lazy.compactMap({ $0 as? UIScrollView }).first {
        let coordinator = context.coordinator
        // Weak: the coordinator owns the observation, which would otherwise keep the
        // coordinator and the page controller alive after the viewer closes.
        coordinator.swipeObservation = scrollView.observe(\.contentOffset, options: [.new]) {
          [weak coordinator, weak controller] scrollView, _ in
          MainActor.assumeIsolated {
            guard let coordinator, let controller else { return }
            coordinator.scrolled(scrollView, controller: controller)
          }
        }
      }
      return controller
    }

    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
      coordinator.swipeObservation?.invalidate()
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
      let coordinator = context.coordinator
      coordinator.count = count
      coordinator.makePage = { AnyView(page($0)) }
      coordinator.onChange = { if index != $0 { index = $0 } }
      coordinator.onSwipe = onSwipe
      coordinator.onTouch = onTouch
      coordinator.pageID = pageID
      guard count > 0 else { return }
      let target = min(max(index ?? 0, 0), count - 1)
      let shown = controller.viewControllers?.first as? PageHost
      let current = shown?.index
      // The same page with another item in it: the library changed under the viewer.
      let changed = current == target && shown?.itemID != nil && shown?.itemID != pageID?(target)
      if let moved = coordinator.relocateDisplayedPage(in: controller, to: target, locate: locate) {
        if moved != target {
          // Reported after this update, which mustn't change state itself.
          let setIndex = $index
          DispatchQueue.main.async { setIndex.wrappedValue = moved }
        }
        return
      }
      let replaced = changed
      // The removed item slides away as it was, not refreshed into the next one.
      if replaced {
        coordinator.outgoing = shown
      }
      if current != target || replaced {
        let forward = (current ?? -1) <= target
        let animated =
          current != nil && (replaced || abs((current ?? target) - target) == 1)
          && !context.transaction.disablesAnimations && !UIAccessibility.isReduceMotionEnabled
        controller.setViewControllers(
          [coordinator.host(target)], direction: forward ? .forward : .reverse, animated: animated)
      }
      // Pages built earlier get the latest state (which one is current, Live Photo playback).
      coordinator.refresh()
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
      var count = 0
      var makePage: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
      var onChange: (Int) -> Void = { _ in }
      var onSwipe: ((CGFloat) -> Void)?
      var onTouch: (() -> Void)?
      var pageID: ((Int) -> String)?
      var swipeObservation: NSKeyValueObservation?
      private let hosts = NSHashTable<PageHost>.weakObjects()

      /// At rest the scroll view sits one page in; a swipe moves it toward 0 or two pages.
      func scrolled(_ scrollView: UIScrollView, controller: UIPageViewController) {
        guard let onSwipe, scrollView.isDragging || scrollView.isDecelerating,
          let current = (controller.viewControllers?.first as? PageHost)?.index
        else { return }
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        if scrollView.isTracking { onTouch?() }
        onSwipe(CGFloat(current) + (scrollView.contentOffset.x - width) / width)
      }

      func host(_ index: Int) -> PageHost {
        let host = PageHost(index: index, itemID: pageID?(index), content: makePage(index))
        hosts.add(host)
        return host
      }

      /// Keep the hosting controller, including its player and zoom, when the item moves.
      func relocateDisplayedPage(
        in controller: UIPageViewController, to target: Int, locate: ((String, Int) -> Int?)?
      ) -> Int? {
        guard let shown = controller.viewControllers?.first as? PageHost, let id = shown.itemID else { return nil }
        let moved: Int?
        if pageID?(target) == id {
          moved = target
        } else if shown.index == target {
          moved = locate?(id, target)
        } else {
          moved = nil
        }
        guard let moved, moved != shown.index, moved >= 0, moved < count else { return nil }
        shown.index = moved
        // Ask for new neighbours without sliding away from the same item.
        controller.setViewControllers([shown], direction: .forward, animated: false)
        refresh()
        return moved
      }

      weak var outgoing: PageHost?

      func refresh() {
        for host in hosts.allObjects where host.index < count && host !== outgoing {
          host.itemID = pageID?(host.index)
          host.rootView = makePage(host.index)
        }
      }

      func pageViewController(
        _ controller: UIPageViewController, viewControllerBefore viewController: UIViewController
      ) -> UIViewController? {
        guard let index = (viewController as? PageHost)?.index, index > 0 else { return nil }
        return host(index - 1)
      }

      func pageViewController(
        _ controller: UIPageViewController, viewControllerAfter viewController: UIViewController
      ) -> UIViewController? {
        guard let index = (viewController as? PageHost)?.index, index + 1 < count else { return nil }
        return host(index + 1)
      }

      func pageViewController(
        _ controller: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
      ) {
        guard let index = (controller.viewControllers?.first as? PageHost)?.index else { return }
        onSwipe?(CGFloat(index))
        if completed { onChange(index) }
      }
    }
  }

#else
  import AppKit

  final class PageHost: NSHostingController<AnyView> {
    var index = 0

    override init(rootView: AnyView) {
      super.init(rootView: rootView)
      // The viewer measures the room its controls take, window toolbar included, and pads
      // each page by it; the safe area would add the toolbar a second time.
      safeAreaRegions = []
      // The page takes the pager's size, which it sets as it shows the page; constraints from
      // the content's own size would keep the size it was made at.
      sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  }

  /// Holds the page on screen. NSPageController doesn't size a page it shows without a
  /// transition (the first one, or one picked by index), which left it 0 by 0.
  private final class PageContainerView: NSView {
    override func layout() {
      super.layout()
      for page in subviews where page.frame != bounds { page.frame = bounds }
    }
  }

  private struct PagedViewerRepresentable<Page: View>: NSViewControllerRepresentable {
    let count: Int
    @Binding var index: Int?
    let page: (Int) -> Page

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// All the room it's offered: the pages are sized from the pager, not the other way.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: NSPageController, context: Context) -> CGSize? {
      proposal.replacingUnspecifiedDimensions()
    }

    func makeNSViewController(context: Context) -> NSPageController {
      let controller = NSPageController()
      controller.view = PageContainerView()
      controller.view.wantsLayer = true
      controller.transitionStyle = .horizontalStrip
      controller.delegate = context.coordinator
      context.coordinator.controller = controller
      return controller
    }

    func updateNSViewController(_ controller: NSPageController, context: Context) {
      let coordinator = context.coordinator
      coordinator.makePage = { AnyView(page($0)) }
      coordinator.onChange = { if index != $0 { index = $0 } }
      if controller.arrangedObjects.count != count {
        // Indices stand in for pages; NSPageController only asks for the visible ones.
        controller.arrangedObjects = Array(0..<count)
      }
      guard count > 0 else { return }
      let target = min(max(index ?? 0, 0), count - 1)
      if controller.selectedIndex != target {
        if abs(controller.selectedIndex - target) == 1,
          !context.transaction.disablesAnimations, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
          NSAnimationContext.runAnimationGroup { _ in controller.animator().selectedIndex = target }
        } else {
          controller.selectedIndex = target
        }
      }
      coordinator.refresh()
    }

    @MainActor
    final class Coordinator: NSObject, NSPageControllerDelegate {
      weak var controller: NSPageController?
      var makePage: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
      var onChange: (Int) -> Void = { _ in }
      private let hosts = NSHashTable<PageHost>.weakObjects()

      func refresh() {
        guard let count = controller?.arrangedObjects.count else { return }
        for host in hosts.allObjects where host.index < count { host.rootView = makePage(host.index) }
      }

      func pageController(_ controller: NSPageController, identifierFor object: Any) -> NSPageController.ObjectIdentifier {
        "page"
      }

      func pageController(
        _ controller: NSPageController, viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier
      ) -> NSViewController {
        let host = PageHost(rootView: AnyView(EmptyView()))
        hosts.add(host)
        return host
      }

      func pageController(_ controller: NSPageController, prepare viewController: NSViewController, with object: Any?) {
        guard let host = viewController as? PageHost, let index = object as? Int else { return }
        host.index = index
        host.rootView = makePage(index)
        if let bounds = self.controller?.view.bounds, bounds.width > 0 { host.view.frame = bounds }
      }

      func pageController(_ controller: NSPageController, didTransitionTo object: Any) {
        if let index = object as? Int { onChange(index) }
      }

      func pageControllerDidEndLiveTransition(_ controller: NSPageController) {
        controller.completeTransition()
      }
    }
  }
#endif
