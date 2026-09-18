import SwiftUI

struct VoiceView: View {
    @Environment(AppState.self) private var state
    @State private var typedQuestion = ""

    private let suggestions = [
        "Top cafés within a 5-minute walk",
        "Where did I park?",
        "Will it rain in the next two hours?",
        "Nearest metro station",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    micButton

                    if state.voice.isListening || !state.voice.transcript.isEmpty {
                        Text(state.voice.transcript.isEmpty ? "Listening…" : state.voice.transcript)
                            .font(.title3)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(state.voice.isListening ? .primary : .secondary)
                    }

                    if state.isAnswering {
                        ProgressView("Thinking…")
                    }

                    if let error = state.voice.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }

                    if case .unavailable(let reason) = state.ai.status {
                        Label(reason, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("Or type a question", text: $typedQuestion)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .onSubmit(submitTyped)
                        Button("Ask", action: submitTyped)
                            .buttonStyle(.glass)
                            .disabled(typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    if state.assistantTurns.isEmpty {
                        suggestionList
                    }

                    ForEach(state.assistantTurns) { turn in
                        AssistantTurnCard(turn: turn)
                    }
                }
                .padding()
            }
            .navigationTitle("Ask PathOS")
            .navigationBarTitleDisplayMode(.inline)
        }
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

    private var micButton: some View {
        Button {
            if state.voice.isListening {
                state.voice.stopListening()
            } else {
                Task { await state.listenAndAnswer() }
            }
        } label: {
            Image(systemName: state.voice.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 40, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: state.voice.isListening)
                .frame(width: 96, height: 96)
        }
        .buttonStyle(.glassProminent)
        .clipShape(Circle())
        .disabled(state.isAnswering)
        .accessibilityLabel(state.voice.isListening ? "Stop listening" : "Start listening")
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button {
                    Task { await state.ask(suggestion) }
                } label: {
                    Text(suggestion)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func submitTyped() {
        let question = typedQuestion.trimmingCharacters(in: .whitespaces)
        guard !question.isEmpty else { return }
        typedQuestion = ""
        Task { await state.ask(question) }
    }
}

private struct AssistantTurnCard: View {
    let turn: AssistantTurn
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(turn.answer)
                .font(.body)

            ForEach(turn.places) { place in
                HStack {
                    Image(systemName: place.symbol)
                        .foregroundStyle(.mint)
                        .frame(width: 24)
                    VStack(alignment: .leading) {
                        Text(place.name).font(.subheadline.weight(.medium))
                        Text("\(place.categoryName) · \(place.walkMinutes) min walk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.isVoicePresented = false
                        let target = CompassTarget(id: place.id, name: place.name, latitude: place.latitude, longitude: place.longitude)
                        Task {
                            // Let the sheet finish dismissing before presenting the pointer.
                            try? await Task.sleep(for: .milliseconds(450))
                            state.startCompass(to: target)
                        }
                    } label: {
                        Image(systemName: "location.north.line.fill")
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Point me to \(place.name)")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}
