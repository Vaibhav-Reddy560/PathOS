import PhotosUI
import SwiftUI

/// Save a memory at your current location: what it is, what kind of place it is, and photos.
struct AddNoteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var radius = 80.0
    @State private var tags: Set<String> = []
    @State private var customTag = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, e.g. Car · Level B2, Pillar C-14", text: $title)
                    TextField("Details", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    InstrumentLabel("Memory")
                }

                Section {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(PlaceTagPresets.all, id: \.self) { tag in
                                let isOn = tags.contains(tag)
                                Button {
                                    if isOn { tags.remove(tag) } else { tags.insert(tag) }
                                } label: {
                                    Text(tag)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(isOn ? Color.void : .ice)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 34)
                                        .background(isOn ? Color.aurora : Color.elevatedSurface, in: .capsule)
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(isOn ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)

                    HStack {
                        TextField("Your own tag", text: $customTag)
                        Button("Add") {
                            let tag = customTag.trimmingCharacters(in: .whitespaces)
                            guard !tag.isEmpty else { return }
                            tags.insert(tag)
                            customTag = ""
                        }
                        .disabled(customTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    InstrumentLabel("What kind of place")
                }

                Section {
                    Slider(value: $radius, in: 50...300, step: 10)
                    MetricText(value: "\(Int(radius))", unit: "m", role: .you)
                } header: {
                    InstrumentLabel("Resurface when within")
                }

                Section {
                    // Read outside the picker's closure: it can't touch view state directly.
                    let attachedLabel = photos.isEmpty ? "Attach photos" : "\(photos.count) attached"
                    PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                        Label(attachedLabel, systemImage: "photo.on.rectangle")
                    }
                    if !photos.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                                    if let image = UIImage(data: data) {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 92, height: 92)
                                            .clipShape(.rect(cornerRadius: 12, style: .continuous))
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.hidden)
                    }
                } header: {
                    InstrumentLabel("Photos")
                } footer: {
                    Text("Saved at your current location. PathOS brings it back when you return.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "location.slash.fill")
                            .foregroundStyle(.amber)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deepSurface)
            .navigationTitle("Save this spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
            .onChange(of: photoItems) { _, items in
                Task {
                    var loaded: [Data] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let compressed = UIImage(data: data)?.jpegData(compressionQuality: 0.5) {
                            loaded.append(compressed)
                        }
                    }
                    photos = loaded
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            guard let here = await state.location.currentLocation() else {
                errorMessage = "Couldn't get your location. Check location permission."
                return
            }
            state.vault.saveNote(
                title: title.trimmingCharacters(in: .whitespaces),
                body: details,
                at: here.coordinate,
                radius: radius,
                photoData: photos.first,
                extraPhotos: Array(photos.dropFirst()),
                tags: tags.sorted()
            )
            await state.vault.syncGeofences(userLocation: here)
            state.haptics.success()
            state.showToast("Spot saved. PathOS will bring it back here")
            dismiss()
        }
    }
}
