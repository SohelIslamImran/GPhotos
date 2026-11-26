import AVFoundation
import SwiftUI

/// The video showing in the viewer, for the controls Photos puts above the filmstrip: play
/// and pause, how far it's played (and scrubbing it), and sound on or off. Pages make the
/// player; the one showing hands it over here.
@MainActor
@Observable
final class VideoPlayback {
  private(set) var player: AVPlayer?
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  /// 0 at the start, 1 at the end.
  private(set) var progress: Double = 0
  private(set) var isMuted = false
  /// Bumped each time a video starts on its own, so the viewer can tuck its controls away.
  private(set) var autoplayCount = 0

  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var statusObservation: NSKeyValueObservation?
  @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
  @ObservationIgnored private var isScrubbing = false
  @ObservationIgnored private var resumesAfterScrub = false

  /// The player of the page now showing, or nil when it isn't a video.
  func stop(_ player: AVPlayer) {
    player.pause()
    player.replaceCurrentItem(with: nil)
    if self.player === player { attach(nil) }
  }

  func attach(_ newPlayer: AVPlayer?) {
    guard newPlayer !== player else { return }
    detach()
    player = newPlayer
    progress = 0
    isBuffering = false
    guard let newPlayer else { return }
    newPlayer.isMuted = isMuted
    isPlaying = newPlayer.timeControlStatus != .paused
    isBuffering = newPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
    // KVO reports on the thread that made the change, which isn't promised to be main.
    statusObservation = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      let playing = player.timeControlStatus != .paused
      let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      Task { @MainActor in
        guard let self, player === self.player else { return }
        self.isBuffering = buffering
        guard !self.isScrubbing else { return }
        self.isPlaying = playing
      }
    }
    timeObserver = newPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 30), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated { self?.update(time: time) }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: AVPlayerItem.didPlayToEndTimeNotification, object: newPlayer.currentItem, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.progress = 1 }
    }
  }

  /// A page's player started by itself.
  func didAutoplay(_ player: AVPlayer) {
    if player === self.player { autoplayCount &+= 1 }
  }

  func togglePlaying() {
    guard let player else { return }
    if isPlaying {
      player.pause()
    } else {
      // From the end, as in Photos, it plays again from the start.
      if progress >= 0.999 { player.seek(to: .zero) }
      player.play()
    }
  }

  func toggleMuted() {
    isMuted.toggle()
    player?.isMuted = isMuted
  }

  /// Dragging along the progress bar: the video follows the finger, paused, and carries on
  /// playing afterwards if it was.
  func scrub(to fraction: Double) {
    guard let player, let duration = duration(of: player) else { return }
    if !isScrubbing {
      isScrubbing = true
      resumesAfterScrub = isPlaying
      player.pause()
    }
    progress = min(max(fraction, 0), 1)
    let time = CMTime(seconds: duration * progress, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func endScrub() {
    guard isScrubbing else { return }
    isScrubbing = false
    if resumesAfterScrub, progress < 0.999 { player?.play() }
  }

  private func update(time: CMTime) {
    guard !isScrubbing, let player, let duration = duration(of: player), duration > 0 else { return }
    progress = min(max(time.seconds / duration, 0), 1)
  }

  private func duration(of player: AVPlayer) -> Double? {
    guard let seconds = player.currentItem?.duration.seconds, seconds.isFinite else { return nil }
    return seconds
  }

  private func detach() {
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    timeObserver = nil
    endObserver = nil
    statusObservation = nil
    isScrubbing = false
    isPlaying = false
  }
}

/// Play or pause, the progress bar and sound, in one piece of glass, as in Photos.
struct VideoControls: View {
  let playback: VideoPlayback

  var body: some View {
    HStack(spacing: 10) {
      Button {
        playback.togglePlaying()
      } label: {
        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
          .font(.body)
          .frame(width: 36, height: 36)
          .contentTransition(.symbolEffect(.replace))
          .contentShape(.rect)
      }
      .accessibilityLabel(Text(playback.isPlaying ? "Pause" : "Play"))
      VideoProgressBar(playback: playback)
      Button {
        playback.toggleMuted()
      } label: {
        Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(width: 36, height: 36)
          .contentTransition(.symbolEffect(.replace))
          .contentShape(.rect)
      }
      .accessibilityLabel(Text(playback.isMuted ? "Unmute" : "Mute"))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .frame(height: 54)
    .glassEffect(.regular.interactive(), in: .capsule)
  }
}

/// How far the video has played; dragging it scrubs. Kept apart so only the bar redraws
/// as it plays.
private struct VideoProgressBar: View {
  let playback: VideoPlayback

  var body: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        Capsule().fill(.primary).frame(width: max(4, width * playback.progress))
      }
      .frame(height: 4)
      .frame(maxHeight: .infinity)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            guard width > 0 else { return }
            playback.scrub(to: value.location.x / width)
          }
          .onEnded { _ in playback.endScrub() }
      )
    }
    .frame(height: 36)
    .accessibilityElement()
    .accessibilityLabel(Text("Playback Position"))
    .accessibilityValue(Text(playback.progress, format: .percent.precision(.fractionLength(0))))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: playback.scrub(to: playback.progress + 0.1)
      case .decrement: playback.scrub(to: playback.progress - 0.1)
      @unknown default: break
      }
      playback.endScrub()
    }
  }
}
