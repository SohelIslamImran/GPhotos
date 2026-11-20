#if os(iOS) && canImport(ActivityKit)
  @preconcurrency import ActivityKit

  // swift-format-ignore: AvoidRetroactiveConformances
  extension Activity: @unchecked @retroactive Sendable {}

  import Foundation
  import GPhotosKit

  @MainActor
  final class LiveActivityController {
    static let shared = LiveActivityController()

    typealias State = BackupActivityAttributes.ContentState
    private var activity: Activity<BackupActivityAttributes>?
    private var latest: State?
    private var publisher: Task<Void, Never>?

    private init() {}

    var isActive: Bool { activity != nil }

    func endStaleActivitiesAtLaunch() {
      // A fresh state, not the stored one: an activity from an older build may not decode.
      let state = State(
        phase: .ended, completedCount: 0, totalCount: 0, bytesSent: 0, bytesTotal: 0, etaText: "", outcome: .stopped)
      for activity in Activity<BackupActivityAttributes>.activities {
        Task { await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate) }
      }
    }

    func start(_ state: State) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      if activity != nil {
        update(state)
        return
      }

      guard
        let activity = try? Activity.request(
          attributes: BackupActivityAttributes(), content: Self.content(state))
      else { return }
      self.activity = activity
      latest = state
      publisher = Task { [weak self] in
        var published = state
        var lastUpdate = ContinuousClock.now
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(1))
          guard !Task.isCancelled, let self, let latest = self.latest else { return }
          if activity.activityState == .dismissed || activity.activityState == .ended {
            self.activity = nil
            self.latest = nil
            self.publisher = nil
            return
          }
          let now = ContinuousClock.now
          guard LiveActivityThrottle.shouldUpdate(elapsed: now - lastUpdate, stateChanged: latest != published)
          else { continue }
          published = latest
          lastUpdate = now
          await activity.update(Self.content(latest))
        }
      }
    }

    func update(_ state: State) {
      guard activity != nil else { return }
      latest = state
    }

    func appWillTerminate() {
      guard let latest else { return }
      end(completed: latest.completedCount, total: latest.totalCount, stopped: true)
    }

    func end(completed: Int, total: Int, stopped: Bool = false) {
      guard let activity, var state = latest else { return }
      let publisher = self.publisher
      publisher?.cancel()
      self.publisher = nil
      self.activity = nil
      latest = nil

      state.phase = .ended
      state.outcome = BackupActivityOutcome(completed: completed, total: total, stopped: stopped)
      state.completedCount = completed
      state.totalCount = max(total, completed)
      state.etaText = ""
      state.currentFilename = nil
      Task { [state] in
        await publisher?.value
        await activity.end(
          .init(state: state, staleDate: nil),
          dismissalPolicy: stopped ? .immediate : .after(Date().addingTimeInterval(5 * 60)))
      }
    }

    private static func content(_ state: State) -> ActivityContent<State> {
      .init(state: state, staleDate: Date().addingTimeInterval(90))
    }
  }
#endif
