import AuthenticationServices
import CoreLocation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var testResult: String?
    @State private var isConfirmingDisconnect = false
    @AppStorage(CalendarEventSource.enabledKey) private var showsCalendarEvents = false
    @State private var calendarNote: String?

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

                gmailSection

                Section {
                    Toggle("Show events from my calendars", isOn: $showsCalendarEvents)
                        .onChange(of: showsCalendarEvents) { _, isOn in
                            guard isOn else { return }
                            Task {
                                if await CalendarEventSource.requestAccess() {
                                    calendarNote = nil
                                } else {
                                    showsCalendarEvents = false
                                    calendarNote = "Calendar access is off. Allow Full Access in Settings → PathOS → Calendars."
                                }
                            }
                        }
                    if let calendarNote {
                        Text(calendarNote)
                            .font(.footnote)
                            .foregroundStyle(.amber)
                    }
                } header: {
                    InstrumentLabel("Calendars")
                } footer: {
                    Text("Events in the next week appear on the map and in Radar with their times. To find events around you, subscribe to public calendars (a Meetup group, your college's fest calendar, a team's fixtures) in Settings → Calendar → Accounts → Add Subscribed Calendar. PathOS's own events aren't shown twice.")
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
                    ForEach(MetroNetwork.data.sources, id: \.what) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.what)
                                .foregroundStyle(.ice)
                            Text([source.licence, "read \(source.retrieved)"].joined(separator: " · "))
                                .foregroundStyle(.mist)
                            if let url = URL(string: source.url), !source.url.isEmpty {
                                Link(url.host() ?? source.url, destination: url)
                            }
                        }
                    }
                    Text("BMRCL publishes no live train positions, platform numbers or machine-readable timetable, so journey times are estimates and PathOS tracks your position rather than the train's.")
                        .foregroundStyle(.mist)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bus stops, routes and timetables")
                            .foregroundStyle(.ice)
                        Text("ODbL 1.0 · contains data from bmtc-gtfs, a community copy of the Namma BMTC app's data; some contents © BMTC. Its timetables are known to be inaccurate, and routes without live tracking are missing.")
                            .foregroundStyle(.mist)
                        Link("github.com", destination: URL(string: "https://github.com/Vonter/bmtc-gtfs")!)
                    }
                } header: {
                    InstrumentLabel("About the transit data")
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

    @ViewBuilder
    private var gmailSection: some View {
        let mail = state.mail
        Section {
            switch mail.connection {
            case .disconnected:
                Text("PathOS can read new mail on your iPhone and pick out events, deadlines and updates. You approve each one before it goes on your Day.")
                Button(mail.isConnecting ? "Connecting…" : "Connect Gmail", action: connectGmail)
                    .disabled(mail.isConnecting)
            case .connected:
                LabeledContent("Account", value: mail.account ?? "Connected")
                LabeledContent("Last checked", value: mail.lastCheckedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "Not yet")
                Button(mail.isChecking ? "Checking…" : "Check now") {
                    Task { await mail.check() }
                }
                .disabled(mail.isChecking)
                Button("Disconnect", role: .destructive) { isConfirmingDisconnect = true }
            case .expired:
                Text("Google signed PathOS out. It does this every 7 days while PathOS is a test app.")
                Button(mail.isConnecting ? "Connecting…" : "Reconnect Gmail", action: connectGmail)
                    .disabled(mail.isConnecting)
                Button("Disconnect", role: .destructive) { isConfirmingDisconnect = true }
            }
            if let error = mail.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.amber)
            }
        } header: {
            InstrumentLabel("Gmail")
        } footer: {
            Text("Read-only: PathOS can't send, change or delete mail. Messages are read on your iPhone and only a one-line summary is kept. Promotions and social mail are skipped.")
        }
        .confirmationDialog("Disconnect Gmail?", isPresented: $isConfirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                Task { await mail.disconnect() }
            }
        } message: {
            Text("Suggestions waiting for you are cleared. Events you've already added stay on your Day.")
        }
    }

    private func connectGmail() {
        Task { await state.mail.connect(present: webAuthenticationSession.googleSignIn) }
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
