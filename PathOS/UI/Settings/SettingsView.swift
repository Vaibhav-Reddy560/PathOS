import AuthenticationServices
import CoreLocation
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var testResult: String?
    /// The Gmail account you asked to disconnect, while you confirm.
    @State private var accountToDisconnect: String?
    @AppStorage(CalendarEventSource.enabledKey) private var showsCalendarEvents = false
    @State private var calendarNote: String?
    @State private var appIcon = AppIconChoice.current
    @State private var backupToShare: URL?
    @State private var backupNote: String?
    @State private var isImportingBackup = false
    /// The TomTom key being typed, and what trying it said.
    @State private var trafficKey = ""
    @State private var trafficNote: String?
    @State private var isCheckingTrafficKey = false

    var body: some View {
        @Bindable var state = state
        @Bindable var routine = state.routine

        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        PathOSMark(height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PathOS")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.ice)
                            Text(versionLine)
                                .font(.footnote)
                                .foregroundStyle(.mist)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                appIconSection
                dataSection

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
                    Text("The app also stops running 7 days after it's installed until it's installed again. Installing it again keeps everything you've saved — see Your data above.")
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
                    Toggle("Say urgent alerts twice", isOn: $state.repeatsUrgentAlerts)
                    LabeledContent("Right now", value: state.sound.scene.label)
                    if let heard = SoundClassifier.lastHeard, state.sound.scene == .unknown {
                        LabeledContent("Last heard", value: "\(heard.scene.label), \(heard.at.formatted(.relative(presentation: .named)))")
                            .font(.footnote)
                    }
                } header: {
                    InstrumentLabel("Sound scene")
                } footer: {
                    Text("The microphone is only listened to while PathOS is open, so a locked phone in a loud place is something PathOS can't hear. What it heard last is remembered instead: anything urgent then breaks through a Focus, is said a second time after 45 seconds in case the first buzz was missed, and is spoken aloud while you're following a way. Opening PathOS cancels the second one. Quiet places get gentle, silent alerts.")
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

                liveTrafficSection

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
                    ForEach(RoadFares.data.sources, id: \.what) { source in
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
                    Text("Fares for autos, bike taxis and cabs are shown as ranges because only the auto's is set by the city; app fares move with demand, and PathOS never states one as a price.")
                        .foregroundStyle(.mist)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch screen map")
                            .foregroundStyle(.ice)
                        Text("Central Bengaluru · © OpenStreetMap contributors, ODbL 1.0")
                            .foregroundStyle(.mist)
                        Link("openstreetmap.org/copyright", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    }
                } header: {
                    InstrumentLabel("About the transit data")
                }
                .font(.footnote)

                Section {
                    Text("**Action Button:** Settings → Action Button → Shortcut → PathOS → *Ask PathOS*.")
                    Text("**Lock Screen every morning:** Shortcuts → Automation → Time of Day → *Pin Context to Lock Screen* (set to run immediately). It pins the context without opening the app.")
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
                                    .init(mode: .exitCheck, title: advice.headline, subtitle: advice.detail, symbol: advice.symbol, deepLink: URL(string: "pathos://dashboard")),
                                    lane: .alert
                                )
                                state.haptics.alert()
                                testResult = advice.headline
                            } else {
                                testResult = "No umbrella needed right now."
                            }
                        }
                    }
                    Button("End Live Activity") {
                        Task {
                            await state.unpinContext()
                            await state.liveActivities.endAll()
                        }
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
            .fileImporter(isPresented: $isImportingBackup, allowedContentTypes: [.json]) { result in
                restore(from: result)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Keeping the data: what survives, what doesn't, and the file that always does.
    /// A TomTom key, for colouring the route you drive by the traffic on it.
    private var liveTrafficSection: some View {
        Section {
            if state.routeTraffic.hasKey {
                Label("On: the route you drive shows its traffic", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.aurora)
                if let problem = state.routeTraffic.problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.amber)
                }
                Button("Turn off and forget the key", role: .destructive) {
                    state.routeTraffic.forgetKey()
                    trafficNote = nil
                }
            } else {
                SecureField("Paste your TomTom key", text: $trafficKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Button {
                    isCheckingTrafficKey = true
                    Task {
                        trafficNote = await state.routeTraffic.save(key: trafficKey)
                        isCheckingTrafficKey = false
                        if state.routeTraffic.hasKey { trafficKey = "" }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isCheckingTrafficKey { ProgressView().controlSize(.small) }
                        Text(isCheckingTrafficKey ? "Checking…" : "Save and check")
                    }
                }
                .disabled(trafficKey.trimmingCharacters(in: .whitespaces).isEmpty || isCheckingTrafficKey)
                if let url = URL(string: "https://developer.tomtom.com/user/register") {
                    Link("Get a free key from TomTom", destination: url)
                }
            }
            if let trafficNote {
                Text(trafficNote)
                    .font(.footnote)
                    .foregroundStyle(.mist)
            }
        } header: {
            InstrumentLabel("Live traffic")
        } footer: {
            Text("Colours the route you're driving amber to red where it's slow. Apple doesn't give apps its traffic for a street, so this asks TomTom: sign up free, copy the key from your dashboard, paste it here. The free plan is 2,500 requests a day with no card, and past that TomTom refuses rather than charges; PathOS uses about 30 an hour of driving. The route ahead is sent to TomTom to be checked. The key stays in this phone's Keychain.")
        }
    }

    private var dataSection: some View {
        Section {
            LabeledContent("On this iPhone", value: state.backups.archive().summary)
                .font(.footnote)

            Button("Back up to a file", systemImage: "square.and.arrow.up") {
                backUp()
            }
            if let backupToShare {
                ShareLink(item: backupToShare) {
                    Label("Save or send the backup", systemImage: "tray.and.arrow.up")
                }
            }
            Button("Restore from a backup", systemImage: "square.and.arrow.down") {
                isImportingBackup = true
            }
            if let lastBackup = state.backups.lastBackupAt {
                LabeledContent("Last backup", value: lastBackup.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
            }
            if let backupNote {
                Text(backupNote)
                    .font(.footnote)
                    .foregroundStyle(backupNote.hasPrefix("Couldn't") ? .coral : .aurora)
            }
        } header: {
            InstrumentLabel("Your data")
        } footer: {
            Text("Everything you save — places, memories and their photos, events, your schedule, trips, mail, expenses — lives on this iPhone in PathOS's own storage. Installing the app again every seven days keeps it, and so does an iPhone backup; deleting the app does not. PathOS writes a backup file every couple of days into **Files → On My iPhone → PathOS**. Keep one copy in iCloud Drive and nothing can be lost. The Google sign-in is deliberately left out of it — sign in again after restoring.")
        }
    }

    private func backUp() {
        do {
            let url = try state.backups.write()
            backupToShare = url
            backupNote = "Saved to Files → On My iPhone → PathOS."
        } catch {
            backupNote = "Couldn't write the backup: \(error.localizedDescription)"
        }
    }

    private func restore(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            let archive = try state.backups.restore(from: Data(contentsOf: url))
            backupNote = "Restored \(archive.summary)."
            Task { await state.reloadAfterRestore() }
        } catch {
            backupNote = "Couldn't read that backup: \(error.localizedDescription)"
        }
    }

    private var appIconSection: some View {
        Section {
            ForEach(AppIconChoice.allCases) { choice in
                Button {
                    Task {
                        // iOS confirms the change with its own alert, showing the new icon.
                        try? await UIApplication.shared.setAlternateIconName(choice.alternateName)
                        appIcon = AppIconChoice.current
                    }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.title)
                                .foregroundStyle(.ice)
                            Text(choice.detail)
                                .font(.footnote)
                                .foregroundStyle(.mist)
                        }
                        Spacer(minLength: 8)
                        if appIcon == choice {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.aurora)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(appIcon == choice ? .isSelected : [])
            }
        } header: {
            InstrumentLabel("App icon")
        }
    }

    @ViewBuilder
    private var gmailSection: some View {
        let mail = state.mail
        Section {
            if mail.accounts.isEmpty {
                Text("PathOS can read new mail on your iPhone and pick out events, deadlines and updates. You approve each one before it goes on your Day.")
            }
            ForEach(mail.accounts) { account in
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.email)
                        .foregroundStyle(.ice)
                    Text(account.isSignedIn
                         ? "Checked " + (account.lastCheckedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "not yet")
                         : "Signed out by Google")
                        .font(.footnote)
                        .foregroundStyle(account.isSignedIn ? .mist : .amber)
                    if !account.isSignedIn {
                        Button(mail.isConnecting ? "Connecting…" : "Sign in again") { connectGmail(account.email) }
                            .disabled(mail.isConnecting)
                    }
                }
                .swipeActions {
                    Button("Disconnect", role: .destructive) { accountToDisconnect = account.email }
                }
                .contextMenu {
                    Button("Disconnect", systemImage: "xmark", role: .destructive) { accountToDisconnect = account.email }
                }
            }
            Button(mail.isConnecting ? "Connecting…" : mail.accounts.isEmpty ? "Connect Gmail" : "Add another Gmail account") {
                connectGmail(nil)
            }
            .disabled(mail.isConnecting)
            if !mail.accounts.isEmpty {
                Button(mail.isChecking ? "Checking…" : "Check now") {
                    Task { await mail.check() }
                }
                .disabled(mail.isChecking)
                NavigationLink("Priority and muted senders") { MailSendersView() }
            }
            if let error = mail.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.amber)
            }
        } header: {
            InstrumentLabel("Gmail")
        } footer: {
            Text("Read-only: PathOS can't send, change or delete mail. Messages are read on your iPhone and only a one-line summary is kept. Promotions and social mail are skipped. Swipe an account to disconnect it.")
        }
        .confirmationDialog(
            "Disconnect \(accountToDisconnect ?? "Gmail")?",
            isPresented: Binding { accountToDisconnect != nil } set: { if !$0 { accountToDisconnect = nil } },
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                if let email = accountToDisconnect {
                    Task { await mail.disconnect(email) }
                }
            }
        } message: {
            Text("Suggestions from this account that are waiting for you are cleared. Events you've already added stay on your Day.")
        }
    }

    private func connectGmail(_ email: String?) {
        Task { await state.mail.connect(present: webAuthenticationSession.googleSignIn, reconnecting: email) }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
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

/// The icon on your Home Screen: the usual one, or the map-only trial.
private enum AppIconChoice: String, CaseIterable, Identifiable {
    case route
    case map

    var id: Self { self }

    static var current: AppIconChoice {
        UIApplication.shared.alternateIconName == AppIconChoice.map.alternateName ? .map : .route
    }

    /// nil is the app's main icon.
    var alternateName: String? {
        switch self {
        case .route: nil
        case .map: "AppIconMap"
        }
    }

    var title: String {
        switch self {
        case .route: "With a route"
        case .map: "Map only"
        }
    }

    var detail: String {
        switch self {
        case .route: "The mark on a city map, with a green route to an orange pin."
        case .map: "Trial: just the mark, on a sharper, more detailed map."
        }
    }
}
