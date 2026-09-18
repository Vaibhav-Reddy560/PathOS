import CoreLocation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: String?

    var body: some View {
        @Bindable var state = state
        @Bindable var routine = state.routine

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Location", value: locationStatus)
                    LabeledContent("Notifications", value: state.notifications.isAuthorized ? "On" : "Off")
                    LabeledContent("Live Activities", value: state.liveActivities.areActivitiesEnabled ? "On" : "Off")
                    Button("Request permissions") {
                        Task { await state.requestCorePermissions() }
                    }
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    InstrumentLabel("Permissions")
                }

                Section {
                    Text("PathOS sends alerts from your iPhone itself — rain and pressure changes, arrivals at your saved places, and departure reminders. It can't use push notifications on a free Apple ID.")
                    Text("iOS decides when a backgrounded app may check, usually every 15–60 minutes, so an alert can lag the weather a little.")
                    Text("The app also stops running 7 days after it's installed until it's installed again. Your data is kept.")
                } header: {
                    InstrumentLabel("How alerts work")
                }
                .font(.footnote)

                Section {
                    switch state.ai.status {
                    case .available:
                        Label("On-device model ready", systemImage: "apple.intelligence")
                            .foregroundStyle(.ion)
                    case .unavailable(let reason):
                        Label(reason, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.amber)
                    }
                } header: {
                    InstrumentLabel("Apple Intelligence")
                } footer: {
                    Text("Scans, the Radar stream and voice answers run entirely on your iPhone. Nothing is sent to a server.")
                }

                Section {
                    Toggle("Adapt alerts to surroundings", isOn: $state.adaptiveSound)
                    LabeledContent("Right now", value: state.sound.scene.label)
                } header: {
                    InstrumentLabel("Sound scene")
                } footer: {
                    Text("Noisy places get strong double haptics; quiet places get gentle, silent alerts. The mic is only analysed while PathOS is open.")
                }

                Section {
                    Toggle("Departure reminders", isOn: $routine.remindersEnabled)
                    ForEach(1...7, id: \.self) { weekday in
                        if let minutes = routine.typicalDepartures[weekday] {
                            LabeledContent(Calendar.current.weekdaySymbols[weekday - 1], value: RoutineLearner.format(minutes: minutes))
                                .monospacedDigit()
                        }
                    }
                    if routine.typicalDepartures.isEmpty {
                        Text("Learned from \(routine.loggedDepartures) departure(s) so far. Needs at least \(RoutineModel.minimumSamples).")
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                    Picker("Preferred cab", selection: $state.preferredCab) {
                        ForEach(CabProvider.allCases) { provider in
                            Text(provider.name).tag(provider)
                        }
                    }
                } header: {
                    InstrumentLabel("Commute")
                }

                Section {
                    Text("Metro lines and station order come from Wikipedia's Namma Metro line articles (CC BY-SA), read 17 September 2026. Station coordinates are looked up in Apple Maps on your iPhone.")
                    Text("BMRCL publishes no live train positions, so journey times are estimates from the station order, not a timetable.")
                } header: {
                    InstrumentLabel("About the data")
                }
                .font(.footnote)

                Section {
                    Text("**Action Button:** Settings → Action Button → Shortcut → PathOS → *Ask PathOS*.")
                    Text("**Hands-free commute:** Shortcuts → Automation → Time of Day → *Start Commute* (set to run immediately). It updates your Lock Screen without opening the app.")
                    Text("**Siri:** “Save my spot in PathOS”, “Find my spot with PathOS”.")
                } header: {
                    InstrumentLabel("Hardware shortcuts")
                }
                .font(.footnote)

                Section {
                    Button("Run exit check now") {
                        Task {
                            if let advice = await state.context.evaluateExit(at: state.location.location) {
                                await state.liveActivities.show(
                                    .init(mode: .exitCheck, title: advice.headline, subtitle: advice.detail, symbol: advice.symbol, deepLink: URL(string: "pathos://dashboard"))
                                )
                                state.haptics.alert()
                                testResult = advice.headline
                            } else {
                                testResult = "No umbrella needed right now."
                            }
                        }
                    }
                    Button("End Live Activity") {
                        Task { await state.liveActivities.end() }
                    }
                    .foregroundStyle(.coral)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.mist)
                    }
                } header: {
                    InstrumentLabel("Test")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var locationStatus: String {
        switch state.location.authorization {
        case .authorizedAlways: "Always"
        case .authorizedWhenInUse: "While using (Always recommended)"
        case .denied: "Denied"
        case .restricted: "Restricted"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}
