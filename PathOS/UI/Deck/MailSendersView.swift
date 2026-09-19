import SwiftUI

/// Who comes first in your mail, and who never shows: add an address, or "@college.edu" for
/// everyone there; swipe to remove.
struct MailSendersView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var newPriority = ""
    @State private var newMuted = ""
    @State private var problem: String?

    var body: some View {
        let mail = state.mail
        Form {
            Section {
                ForEach(mail.prioritySenders, id: \.self) { rule in
                    Label(rule, systemImage: rule.hasPrefix("@") ? "person.2.fill" : "star.fill")
                }
                .onDelete { offsets in
                    for rule in offsets.map({ mail.prioritySenders[$0] }) { mail.setPriority(rule, false) }
                }
                adder("Address or @domain", text: $newPriority) { mail.setPriority($0, true) }
            } header: {
                InstrumentLabel("Priority")
            } footer: {
                Text("Their mail comes first in Day, under Priority. \"@bmsce.ac.in\" covers everyone at your college.")
            }

            Section {
                ForEach(mail.mutedSenders, id: \.self) { rule in
                    Label(rule, systemImage: "speaker.slash.fill")
                }
                .onDelete { offsets in
                    for rule in offsets.map({ mail.mutedSenders[$0] }) { mail.setMuted(rule, false) }
                }
                adder("Address or @domain", text: $newMuted) { mail.setMuted($0, true) }
            } header: {
                InstrumentLabel("Muted")
            } footer: {
                Text("Their new mail isn't read or shown, and never notifies you.")
            }

            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.amber)
            }
        }
        .navigationTitle("Senders")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func adder(_ prompt: String, text: Binding<String>, add: @escaping (String) -> Bool) -> some View {
        HStack {
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .submitLabel(.done)
                .onSubmit { submit(text, add) }
            Button("Add") { submit(text, add) }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit(_ text: Binding<String>, _ add: (String) -> Bool) {
        if add(text.wrappedValue) {
            text.wrappedValue = ""
            problem = nil
        } else {
            problem = "That isn't an email address or a domain like @college.edu."
        }
    }
}
