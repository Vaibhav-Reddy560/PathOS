import ActivityKit
import Foundation
import Observation

/// Owns PathOS's Live Activities: one per lane, so two things happening at once each get a whole
/// card on the Lock Screen.
///
/// It used to own exactly one. Everything worth showing — the pinned context, a journey, a note
/// you left here — took turns on it, and whatever lost the turn was squeezed into a one-line note
/// underneath or dropped to a notification. A card each says all of it, and each says it fully.
@Observable
final class LiveActivityController {
    typealias ContentState = PathOSActivityAttributes.ContentState
    typealias Mode = PathOSActivityAttributes.Mode

    /// What each lane is showing, for the callers that ask before they replace something.
    private(set) var modes: [ActivityLane: Mode] = [:]

    @ObservationIgnored private var activities: [ActivityLane: Activity<PathOSActivityAttributes>] = [:]
    @ObservationIgnored private var lastStates: [ActivityLane: ContentState] = [:]
    @ObservationIgnored private var lastThrottledUpdate: [ActivityLane: Date] = [:]

    init() {
        // Cards PathOS started before it was last closed are still on the Lock Screen.
        for running in Activity<PathOSActivityAttributes>.activities where running.activityState == .active {
            let lane = running.attributes.lane
            activities[lane] = running
            lastStates[lane] = running.content.state
            modes[lane] = running.content.state.mode
        }
    }

    /// iOS ends a Live Activity after this long.
    static let longestRun: TimeInterval = 8 * 3_600

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func isRunning(_ lane: ActivityLane) -> Bool {
        activities[lane]?.activityState == .active
    }

    func mode(of lane: ActivityLane) -> Mode? { modes[lane] }

    /// Any card at all, for the places that only care whether the Lock Screen has something.
    var isRunning: Bool { ActivityLane.allCases.contains { isRunning($0) } }

    // MARK: When you swiped one away

    private func startedAtKey(_ lane: ActivityLane) -> String { "pathos.activityStartedAt.\(lane.rawValue)" }
    private func bootKey(_ lane: ActivityLane) -> String { "pathos.activityBoot.\(lane.rawValue)" }

    func startedAt(_ lane: ActivityLane) -> Date? {
        UserDefaults.standard.object(forKey: startedAtKey(lane)) as? Date
    }

    private static var bootTime: Date {
        Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
    }

    /// Nothing on the Lock Screen, though PathOS never ended it, iOS's eight hours weren't up and
    /// the phone hasn't restarted since: you swiped it away.
    func wasRemovedByYou(_ lane: ActivityLane) -> Bool {
        guard !isRunning(lane), let startedAt = startedAt(lane) else { return false }
        if let boot = UserDefaults.standard.object(forKey: bootKey(lane)) as? Date,
           abs(boot.timeIntervalSince(Self.bootTime)) > 60 {
            return false
        }
        return Date().timeIntervalSince(startedAt) < Self.longestRun - 5 * 60
    }

    // MARK: Showing

    @discardableResult
    func show(_ state: ContentState, lane: ActivityLane, staleAfter: TimeInterval = 3_600, relevance: Double = 50) async -> Bool {
        await show(state, lane: lane, staleDate: Date().addingTimeInterval(staleAfter), relevance: relevance)
    }

    @discardableResult
    func show(_ state: ContentState, lane: ActivityLane, staleDate: Date, relevance: Double = 50) async -> Bool {
        let content = ActivityContent(state: state, staleDate: staleDate, relevanceScore: relevance)

        if let activity = activities[lane], activity.activityState == .active {
            await Self.update(id: activity.id, to: content)
            remember(state, lane: lane)
            return true
        }
        return await start(content, lane: lane, allowingRoom: true)
    }

    /// Like `show`, but skips the update when nothing on screen would change — for trackers that
    /// recompute every few seconds.
    @discardableResult
    func showIfChanged(_ state: ContentState, lane: ActivityLane, staleAfter: TimeInterval = 3_600, relevance: Double = 50) async -> Bool {
        if isRunning(lane), lastStates[lane] == state { return true }
        return await show(state, lane: lane, staleAfter: staleAfter, relevance: relevance)
    }

    @discardableResult
    func showIfChanged(_ state: ContentState, lane: ActivityLane, staleDate: Date, relevance: Double = 50) async -> Bool {
        if isRunning(lane), lastStates[lane] == state { return true }
        return await show(state, lane: lane, staleDate: staleDate, relevance: relevance)
    }

    /// Starts a card. If iOS refuses because too many are running, the least urgent lane gives up
    /// its card and it tries once more — a journey matters more than a note from this morning.
    private func start(_ content: ActivityContent<ContentState>, lane: ActivityLane, allowingRoom: Bool) async -> Bool {
        do {
            let activity = try Activity.request(
                attributes: PathOSActivityAttributes(sessionName: "PathOS", lane: lane),
                content: content,
                pushType: nil
            )
            activities[lane] = activity
            UserDefaults.standard.set(Date(), forKey: startedAtKey(lane))
            UserDefaults.standard.set(Self.bootTime, forKey: bootKey(lane))
            remember(content.state, lane: lane)
            return true
        } catch {
            guard allowingRoom, let spare = laneToGiveUp(for: lane) else { return false }
            await end(spare)
            return await start(content, lane: lane, allowingRoom: false)
        }
    }

    /// The running lane that matters least, as long as it matters less than the one asking.
    private func laneToGiveUp(for lane: ActivityLane) -> ActivityLane? {
        let order = ActivityLane.byImportance
        guard let asking = order.firstIndex(of: lane) else { return nil }
        return order.enumerated().first { index, candidate in
            index < asking && isRunning(candidate)
        }?.element
    }

    /// Starts a card afresh while PathOS is open, once it has run long enough that iOS would end it.
    func renewIfOld(after age: TimeInterval = 4 * 3_600) async {
        for lane in ActivityLane.allCases {
            guard let activity = activities[lane], activity.activityState == .active,
                  let state = lastStates[lane], let startedAt = startedAt(lane),
                  Date().timeIntervalSince(startedAt) > age else { continue }
            let content = activity.content
            await end(lane)
            await show(state, lane: lane,
                       staleDate: content.staleDate ?? Date().addingTimeInterval(3_600),
                       relevance: content.relevanceScore)
        }
    }

    /// For fast-changing data like the compass: skips updates that are too soon or too small,
    /// staying well inside ActivityKit's update budget.
    func updateThrottled(_ state: ContentState, lane: ActivityLane, minInterval: TimeInterval = 3, minBearingChange: Double = 10) async {
        guard let activity = activities[lane], activity.activityState == .active else { return }
        let now = Date()
        guard now.timeIntervalSince(lastThrottledUpdate[lane] ?? .distantPast) >= minInterval else { return }

        if let last = lastStates[lane], last.mode == state.mode {
            let bearingChange = both(last.relativeBearing, state.relativeBearing).map { GeoMath.angularDifference($0.0, $0.1) } ?? .infinity
            let distanceChange = both(last.distanceMeters, state.distanceMeters).map { abs($0.0 - $0.1) } ?? .infinity
            if bearingChange < minBearingChange && distanceChange < 10 {
                return
            }
        }

        lastThrottledUpdate[lane] = now
        remember(state, lane: lane)
        await Self.update(id: activity.id, to: ActivityContent(state: state, staleDate: now.addingTimeInterval(600)))
    }

    // MARK: Ending

    /// Ends one lane's card, optionally only if it is showing `mode`.
    func end(_ lane: ActivityLane, ifMode mode: Mode? = nil) async {
        if let mode, modes[lane] != mode { return }
        if let id = activities[lane]?.id {
            await Self.end(id: id)
        }
        forget(lane)
    }

    /// Ends every card PathOS has up, including any left from an older build.
    func endAll() async {
        for running in Activity<PathOSActivityAttributes>.activities {
            await running.end(nil, dismissalPolicy: .immediate)
        }
        for lane in ActivityLane.allCases { forget(lane) }
    }

    // MARK: Pieces

    /// Swift 6 won't pass the main-actor-held activity into ActivityKit's concurrent `update`,
    /// so look it up again by ID here instead.
    nonisolated private static func update(id: String, to content: ActivityContent<ContentState>) async {
        await Activity<PathOSActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    /// Ended by ID for the same reason updates are: the activity itself can't cross actors.
    nonisolated private static func end(id: String) async {
        await Activity<PathOSActivityAttributes>.activities.first { $0.id == id }?
            .end(nil, dismissalPolicy: .immediate)
    }

    private func remember(_ state: ContentState, lane: ActivityLane) {
        lastStates[lane] = state
        modes[lane] = state.mode
    }

    private func forget(_ lane: ActivityLane) {
        activities[lane] = nil
        lastStates[lane] = nil
        modes[lane] = nil
        lastThrottledUpdate[lane] = nil
        UserDefaults.standard.removeObject(forKey: startedAtKey(lane))
        UserDefaults.standard.removeObject(forKey: bootKey(lane))
    }
}

private func both<A, B>(_ first: A?, _ second: B?) -> (A, B)? {
    guard let first, let second else { return nil }
    return (first, second)
}
