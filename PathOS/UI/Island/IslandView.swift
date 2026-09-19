import SwiftUI

/// The OS alert layer: a solid Void capsule under the status bar, echoing the Dynamic Island.
/// Compact, it shows the most important thing right now, or PathOS's name when nothing is worth
/// a glance, the way a chat app titles its screen; tapped, it grows to show every alert with its
/// actions. It also becomes the assistant when you ask PathOS something.
///
/// One view, one background: the compact row is always present and only the height changes,
/// so the capsule can never shrink below its own text mid-animation.
struct IslandView: View {
    let alerts: [AmbientAlert]

    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isExpanded = false
    @State private var announcedAlertIDs: Set<String> = []
    @State private var collapseTask: Task<Void, Never>?

    private var isOpen: Bool { isExpanded || state.isAssistantActive }

    var body: some View {
        VStack(spacing: 0) {
            if state.isAssistantActive {
                IslandAssistantPanel()
            } else if let top = alerts.first {
                compactRow(top)
                if isExpanded {
                    expandedList
                }
            }
        }
        .background {
            RoundedRectangle(cornerRadius: isOpen ? 30 : 22, style: .continuous)
                .fill(Color.void)
                .overlay {
                    RoundedRectangle(cornerRadius: isOpen ? 30 : 22, style: .continuous)
                        .strokeBorder(Hairline.style, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        }
        .padding(.horizontal, 12)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .animation(PathMotion.resolve(PathMotion.island, reduceMotion: reduceMotion), value: isExpanded)
        .animation(PathMotion.resolve(PathMotion.island, reduceMotion: reduceMotion), value: state.isAssistantActive)
        // The capsule reshapes when news replaces the name, and when it hands the name back.
        .animation(PathMotion.resolve(PathMotion.island, reduceMotion: reduceMotion), value: alerts.first?.id)
        .onChange(of: alerts.first?.id, initial: true) {
            announceIfNew()
        }
        .onChange(of: state.isAssistantActive) { _, isActive in
            if isActive { collapse() }
        }
        #if DEBUG
        .onAppear {
            // `-PathOSIslandExpanded YES` holds the island open for simulator screenshots.
            if UserDefaults.standard.bool(forKey: "PathOSIslandExpanded") {
                isExpanded = true
            }
        }
        #endif
    }

    // MARK: Compact

    private func compactRow(_ top: AmbientAlert) -> some View {
        let queued = alerts.dropFirst().filter { $0.role != .world && $0.id != "idle" }.count
        let isQuiet = AmbientAlerts.isQuiet(alerts)

        return Button {
            if isExpanded {
                collapse()
            } else {
                expand(autoCollapse: false)
            }
        } label: {
            HStack(spacing: 10) {
                // Open, the list says what's on, so the heading is PathOS rather than a repeat of
                // the first alert.
                if isQuiet || isExpanded {
                    PathOSWordmark()
                        .padding(.horizontal, 2)
                        .transition(.opacity)
                } else {
                    Image(systemName: top.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(top.role.color)
                        .symbolEffect(.breathe, isActive: top.role == .critical && !reduceMotion)
                    Text(top.compactText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ice)
                        .lineLimit(1)
                    if let metric = top.metric {
                        Text(metric)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(top.role.color)
                    }
                    if queued > 0, !isExpanded {
                        Text("+\(queued)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.mist)
                    }
                }
                if isExpanded {
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.mist)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isQuiet ? "PathOS. \(top.headline)" : "\(top.role.spokenPrefix): \(top.headline)")
        .accessibilityHint(isExpanded ? "Collapses" : alerts.count > 1 ? "Shows \(alerts.count) alerts" : "Shows details")
    }

    // MARK: Expanded

    private var expandedList: some View {
        let shown = alerts.filter { $0.id != "idle" || alerts.count == 1 }

        return VStack(alignment: .leading, spacing: 18) {
            ForEach(shown.prefix(4)) { alert in
                AlertRow(alert: alert) {
                    collapse()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                if value.translation.height < -24 { collapse() }
            }
        )
        .onTapGesture {
            // Touching the panel keeps it open.
            collapseTask?.cancel()
        }
    }

    // MARK: Behaviour

    private func expand(autoCollapse: Bool) {
        collapseTask?.cancel()
        isExpanded = true
        guard autoCollapse else { return }
        collapseTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }

    private func collapse() {
        collapseTask?.cancel()
        isExpanded = false
    }

    /// New attention or critical alerts announce themselves, like a Dynamic Island alert.
    private func announceIfNew() {
        guard let top = alerts.first, top.role == .attention || top.role == .critical,
              !announcedAlertIDs.contains(top.id), !state.isAssistantActive else { return }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "PathOSIslandExpanded") { return }
        #endif
        announcedAlertIDs.insert(top.id)
        state.haptics.alert()
        if voiceOverEnabled {
            AccessibilityNotification.Announcement("\(top.role.spokenPrefix): \(top.headline)").post()
        } else {
            expand(autoCollapse: true)
        }
    }
}

private struct AlertRow: View {
    let alert: AmbientAlert
    let onAction: () -> Void

    @Environment(AppState.self) private var state

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SignalGlyph(symbol: alert.symbol, role: alert.role, size: 30)

            // The title is the island's own size and the detail smaller, so an alert never reads
            // louder than the island that holds it.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(alert.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.ice)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let metric = alert.metric {
                        Text(metric)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(alert.role.color)
                    }
                }
                Text(alert.detail)
                    .font(.footnote)
                    .foregroundStyle(.mist)
                    .fixedSize(horizontal: false, vertical: true)

                if !alert.buttons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(alert.buttons, id: \.self) { button in
                            actionButton(button)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(alert.role.spokenPrefix): \(alert.headline). \(alert.detail)")

            if alert.isDismissible {
                Button {
                    state.dismissedAlertIDs.insert(alert.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.mist)
                        .frame(width: 26, height: 26)
                        .background(Color.elevatedSurface, in: .circle)
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                // A full-size target that doesn't push the row's text in.
                .padding(.vertical, -9)
                .padding(.trailing, -9)
                .accessibilityLabel("Dismiss \(alert.headline)")
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ button: AmbientAlert.Button) -> some View {
        let label = Label(button.title, systemImage: button.symbol)
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 30)
        if button.isPrimary {
            Button {
                state.perform(button.action)
                onAction()
            } label: { label }
            .pathPrimaryAction()
        } else {
            Button {
                state.perform(button.action)
                onAction()
            } label: { label }
            .pathSecondaryAction()
        }
    }
}
