import SwiftUI

/// The OS alert layer: a solid Void capsule under the status bar, echoing the Dynamic Island.
/// Compact, it shows the most important thing right now; tapped, it grows to show every alert
/// with its actions. It also becomes the assistant when you ask PathOS something.
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

        return Button {
            if isExpanded {
                collapse()
            } else {
                expand(autoCollapse: false)
            }
        } label: {
            HStack(spacing: 10) {
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
        .accessibilityLabel("\(top.role.spokenPrefix): \(top.headline)")
        .accessibilityHint(isExpanded ? "Collapses" : alerts.count > 1 ? "Shows \(alerts.count) alerts" : "Shows details")
    }

    // MARK: Expanded

    private var expandedList: some View {
        let shown = alerts.filter { $0.id != "idle" || alerts.count == 1 }

        return VStack(alignment: .leading, spacing: 16) {
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SignalGlyph(symbol: alert.symbol, role: alert.role, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.headline)
                        .font(.headline)
                        .foregroundStyle(.ice)
                    Text(alert.detail)
                        .font(.subheadline)
                        .foregroundStyle(.mist)
                }
                Spacer(minLength: 0)
                if let metric = alert.metric {
                    Text(metric)
                        .font(.pathMetric)
                        .foregroundStyle(alert.role.color)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(alert.role.spokenPrefix): \(alert.headline). \(alert.detail)")

            if !alert.buttons.isEmpty || alert.isDismissible {
                HStack(spacing: 8) {
                    ForEach(alert.buttons, id: \.self) { button in
                        if button.isPrimary {
                            Button {
                                state.perform(button.action)
                                onAction()
                            } label: {
                                Label(button.title, systemImage: button.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 30)
                            }
                            .pathPrimaryAction()
                        } else {
                            Button {
                                state.perform(button.action)
                                onAction()
                            } label: {
                                Label(button.title, systemImage: button.symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 30)
                            }
                            .pathSecondaryAction()
                        }
                    }
                    Spacer(minLength: 0)
                    if alert.isDismissible {
                        Button("Dismiss") {
                            state.dismissedAlertIDs.insert(alert.id)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.mist)
                        .frame(minHeight: 44)
                    }
                }
                .padding(.leading, 48)
            }
        }
    }
}
