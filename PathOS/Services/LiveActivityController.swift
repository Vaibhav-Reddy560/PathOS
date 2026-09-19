import ActivityKit
import Foundation
import Observation

/// Owns PathOS's single Live Activity. The mode in its content state decides the layout.
@Observable
final class LiveActivityController {
    typealias ContentState = PathOSActivityAttributes.ContentState
    typealias Mode = PathOSActivityAttributes.Mode

    private(set) var currentMode: Mode?

    @ObservationIgnored private var activity: Activity<PathOSActivityAttributes>?
    @ObservationIgnored private var lastThrottledUpdate = Date.distantPast
    @ObservationIgnored private var lastState: ContentState?

    init() {
        activity = Activity<PathOSActivityAttributes>.activities.first { $0.activityState == .active }
        currentMode = activity?.content.state.mode
        lastState = activity?.content.state
    }

    /// iOS ends a Live Activity after this long.
    static let longestRun: TimeInterval = 8 * 3_600

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var isRunning: Bool { activity?.activityState == .active }

    /// When the running activity was started, kept across launches.
    private(set) var startedAt: Date? {
        get { UserDefaults.standard.object(forKey: "pathos.activityStartedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "pathos.activityStartedAt") }
    }

    /// When the phone last started, when the running activity was started. A restart ends every
    /// Live Activity, which isn't you taking it away.
    private var startedInBoot: Date? {
        get { UserDefaults.standard.object(forKey: "pathos.activityBoot") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "pathos.activityBoot") }
    }

    private static var bootTime: Date {
        Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
    }

    /// Nothing on the Lock Screen, though PathOS never ended it, iOS's eight hours weren't up and
    /// the phone hasn't restarted since: you swiped it away.
    var wasRemovedByYou: Bool {
        guard !isRunning, let startedAt else { return false }
        if let startedInBoot, abs(startedInBoot.timeIntervalSince(Self.bootTime)) > 60 {
            return false
        }
        return Date().timeIntervalSince(startedAt) < Self.longestRun - 5 * 60
    }

    /// Shows `state`, reusing the running activity when there is one.
    /// Returns false when iOS refuses to start a new one (for example from the background).
    @discardableResult
    func show(_ state: ContentState, staleAfter: TimeInterval = 3600, relevance: Double = 50) async -> Bool {
        await show(state, staleDate: Date().addingTimeInterval(staleAfter), relevance: relevance)
    }

    @discardableResult
    func show(_ state: ContentState, staleDate: Date, relevance: Double = 50) async -> Bool {
        let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: relevance)

        if let activity, activity.activityState == .active {
            await Self.update(id: activity.id, to: content)
            remember(state)
            return true
        }

        do {
            activity = try Activity.request(
                attributes: PathOSActivityAttributes(sessionName: "PathOS"),
                content: content,
                pushType: nil
            )
            startedAt = Date()
            startedInBoot = Self.bootTime
            remember(state)
            return true
        } catch {
            return false
        }
    }

    /// Like `show`, but skips the update when nothing on screen would change — for trackers
    /// that recompute every few seconds.
    @discardableResult
    func showIfChanged(_ state: ContentState, staleAfter: TimeInterval = 3600, relevance: Double = 50) async -> Bool {
        if let activity, activity.activityState == .active, lastState == state {
            return true
        }
        return await show(state, staleAfter: staleAfter, relevance: relevance)
    }

    @discardableResult
    func showIfChanged(_ state: ContentState, staleDate: Date, relevance: Double = 50) async -> Bool {
        if let activity, activity.activityState == .active, lastState == state {
            return true
        }
        return await show(state, staleDate: staleDate, relevance: relevance)
    }

    /// Starts the activity afresh while PathOS is open, where iOS allows it, once it has run long
    /// enough that iOS would soon end it.
    func renewIfOld(after age: TimeInterval = 4 * 3_600) async {
        guard let activity, activity.activityState == .active, let lastState,
              let startedAt, Date().timeIntervalSince(startedAt) > age else { return }
        let content = activity.content
        await end()
        await show(lastState, staleDate: content.staleDate ?? Date().addingTimeInterval(3_600), relevance: content.relevanceScore)
    }

    /// For fast-changing data like the compass: skips updates that are too soon or too small,
    /// staying well inside ActivityKit's update budget.
    func updateThrottled(_ state: ContentState, minInterval: TimeInterval = 3, minBearingChange: Double = 10) async {
        guard let activity, activity.activityState == .active else { return }
        let now = Date()
        guard now.timeIntervalSince(lastThrottledUpdate) >= minInterval else { return }

        if let last = lastState, last.mode == state.mode {
            let bearingChange = both(last.relativeBearing, state.relativeBearing).map { GeoMath.angularDifference($0.0, $0.1) } ?? .infinity
            let distanceChange = both(last.distanceMeters, state.distanceMeters).map { abs($0.0 - $0.1) } ?? .infinity
            if bearingChange < minBearingChange && distanceChange < 10 {
                return
            }
        }

        lastThrottledUpdate = now
        remember(state)
        await Self.update(id: activity.id, to: ActivityContent(state: state, staleDate: now.addingTimeInterval(600)))
    }

    /// Ends the activity, optionally only if it is showing `mode`.
    func end(ifMode mode: Mode? = nil) async {
        if let mode, currentMode != mode { return }
        for running in Activity<PathOSActivityAttributes>.activities {
            await running.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        currentMode = nil
        lastState = nil
        startedAt = nil
        startedInBoot = nil
    }

    /// Swift 6 won't pass the main-actor-held `activity` into ActivityKit's concurrent `update`,
    /// so look it up again by ID here instead.
    nonisolated private static func update(id: String, to content: ActivityContent<ContentState>) async {
        await Activity<PathOSActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    private func remember(_ state: ContentState) {
        lastState = state
        currentMode = state.mode
    }
}

private func both<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
