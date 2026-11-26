import SwiftUI

/// A spinner over a photo still sharpening or a video still buffering. Quick loads never
/// show it, and one that gets nowhere (offline) doesn't spin forever.
struct ViewerLoadingIndicator: View {
  let isLoading: Bool
  @State private var isVisible = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      if isVisible {
        // White with a shadow reads on any photo.
        ProgressView()
          .controlSize(.large)
          .tint(.white)
          .shadow(color: .black.opacity(0.5), radius: 6)
          .transition(.opacity)
          .accessibilityLabel("Loading")
      }
    }
    .allowsHitTesting(false)
    .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isVisible)
    .task(id: isLoading) {
      guard isLoading else {
        isVisible = false
        return
      }
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      isVisible = true
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      isVisible = false
    }
  }
}
