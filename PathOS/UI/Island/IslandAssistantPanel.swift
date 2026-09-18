import SwiftUI

/// "Ask PathOS", grown out of the island. The map stays visible; places in the answer
/// appear on it as cyan signals.
struct IslandAssistantPanel: View {
    @Environment(AppState.self) private var state
    @State private var typedQuestion = ""
    @FocusState private var isTyping: Bool

    private let suggestions = [
        "Top cafés within a 5-minute walk",
        "Where did I park?",
        "Will it rain in the next two hours?",
        "Nearest metro station",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let error = state.voice.lastError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.amber)
            }

            if let turn = state.assistantTurns.first, !state.voice.isListening, !state.isAnswering {
                answer(turn)
            } else if state.assistantTurns.isEmpty, !state.voice.isListening, !state.isAnswering {
                suggestionChips
            }

            if case .unavailable(let reason) = state.ai.status {
                Label(reason, systemImage: "apple.intelligence")
                    .font(.caption)
                    .foregroundStyle(.mist)
            }

            HStack(spacing: 8) {
                TextField("Or type a question", text: $typedQuestion)
                    .focused($isTyping)
                    .submitLabel(.send)
                    .onSubmit(submitTyped)
                    .pathField()
                Button(action: submitTyped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 44, height: 44)
                        .contentShape(.circle)
                }
                .pathPrimaryAction()
                .buttonBorderShape(.circle)
                .disabled(typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Ask")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if state.voiceAutoListen {
                state.voiceAutoListen = false
                await state.listenAndAnswer()
            }
        }
        .onDisappear {
            state.voice.cancel()
            state.speech.stop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if state.voice.isListening {
                    state.voice.stopListening()
                } else {
                    isTyping = false
                    Task { await state.listenAndAnswer() }
                }
            } label: {
                Image(systemName: state.voice.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: state.voice.isListening)
                    .frame(width: 48, height: 48)
                    .contentShape(.circle)
            }
            .pathPrimaryAction()
            .buttonBorderShape(.circle)
            .disabled(state.isAnswering)
            .accessibilityLabel(state.voice.isListening ? "Stop listening" : "Start listening")

            VStack(alignment: .leading, spacing: 2) {
                InstrumentLabel(status, role: state.voice.isListening ? .you : nil)
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.ice)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 0)

            Button {
                state.isAssistantActive = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.mist)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close assistant")
        }
    }

    private func answer(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.answer)
                .font(.body)
                .foregroundStyle(.ice)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)

            if !turn.places.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(turn.places) { place in
                            Button {
                                state.selectedSignalID = "place:\(place.id)"
                                state.deckDetent = .medium
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: place.symbol)
                                        .foregroundStyle(.ion)
                                    Text(place.name)
                                        .foregroundStyle(.ice)
                                        .lineLimit(1)
                                    Text("\(place.walkMinutes) min")
                                        .monospacedDigit()
                                        .foregroundStyle(.mist)
                                }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(Color.ion.opacity(0.12), in: .capsule)
                                .overlay { Capsule().strokeBorder(Color.ion.opacity(0.3), lineWidth: 1) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Nearby \(place.name), \(place.walkMinutes) minute walk. Shows it on the map.")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await state.ask(suggestion) }
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.ice)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(Color.elevatedSurface, in: .capsule)
                            .overlay { Capsule().strokeBorder(Hairline.style, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var status: String {
        if state.voice.isListening { return "Listening" }
        if state.isAnswering { return "Thinking on-device" }
        return "Ask PathOS"
    }

    private var headline: String {
        if !state.voice.transcript.isEmpty { return state.voice.transcript }
        if state.voice.isListening { return "Go ahead…" }
        if state.isAnswering { return "Working it out…" }
        return state.assistantTurns.first?.question ?? "What do you need around here?"
    }

    private func submitTyped() {
        let question = typedQuestion.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        typedQuestion = ""
        isTyping = false
        Task { await state.ask(question) }
    }
}
