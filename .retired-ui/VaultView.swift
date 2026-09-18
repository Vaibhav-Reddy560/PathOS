import CoreLocation
import PhotosUI
import SwiftData
import SwiftUI

struct VaultView: View {
    @Environment(AppState.self) private var state
    @Query(sort: \SpatialNote.createdAt, order: .reverse) private var notes: [SpatialNote]
    @Query(sort: \SavedPlace.createdAt) private var places: [SavedPlace]
    @State private var isAddingNote = false

    var body: some View {
        ScrollViewReader { proxy in
            List {
                Section("Spatial notes") {
                    if notes.isEmpty {
                        Text("Save a parking pillar, locker code or anything tied to a place. It resurfaces when you come back.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(notes) { note in
                        NoteRow(note: note, isFocused: state.focusedNoteID == note.id)
                            .id(note.id)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await state.vault.delete(note) }
                                }
                            }
                    }
                }

                Section("Places") {
                    ForEach(places) { place in
                        Label {
                            VStack(alignment: .leading) {
                                Text(place.name)
                                Text("\(Int(place.radius)) m geofence")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: place.kind.symbol).foregroundStyle(.mint)
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await state.vault.delete(place) }
                            }
                        }
                    }
                    ForEach([PlaceKind.home, .work]) { kind in
                        Button("Set \(kind.label) to current location", systemImage: kind.symbol) {
                            Task { await state.setPlaceHere(kind) }
                        }
                    }
                }

                Section {
                    Text("\(state.geofences.monitoredIDs.count) of \(GeofenceMonitor.maxRegions) geofence slots in use. Home and Work always get one; the rest go to your closest notes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Memory Vault")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isAddingNote = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Save this spot")
                }
            }
            .sheet(isPresented: $isAddingNote) { AddNoteSheet() }
            .task(id: state.focusedNoteID) {
                guard let id = state.focusedNoteID else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
                try? await Task.sleep(for: .seconds(4))
                state.focusedNoteID = nil
            }
        }
    }
}

private struct NoteRow: View {
    let note: SpatialNote
    let isFocused: Bool
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            if let data = note.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 12))
            } else {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                    .frame(width: 56, height: 56)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.headline)
                if !note.body.isEmpty {
                    Text(note.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(distanceText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                state.startCompass(to: CompassTarget(id: note.geofenceID, name: note.title, latitude: note.latitude, longitude: note.longitude))
            } label: {
                Image(systemName: "location.north.line.fill")
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Point me to \(note.title)")
        }
        .listRowBackground(isFocused ? Color.yellow.opacity(0.2) : nil)
    }

    private var distanceText: String {
        let saved = note.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let here = state.location.location else { return saved }
        let distance = here.distance(from: CLLocation(latitude: note.latitude, longitude: note.longitude))
        return "\(GeoMath.formatDistance(distance)) away · \(saved)"
    }
}

struct AddNoteSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var radius = 80.0
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title, e.g. Car · Level B2, Pillar C-14", text: $title)
                    TextField("Details", text: $details, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Resurface when within") {
                    Slider(value: $radius, in: 50...300, step: 10)
                    Text("\(Int(radius)) m")
                        .foregroundStyle(.secondary)
                }

                Section {
                    PhotosPicker("Attach a photo", selection: $photoItem, matching: .images)
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                    }
                }

                Section {
                    Text("Saved at your current location. PathOS brings it back when you return.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
            }
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
            .onChange(of: photoItem) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self) else { return }
                    photoData = UIImage(data: data)?.jpegData(compressionQuality: 0.5)
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
                photoData: photoData
            )
            await state.vault.syncGeofences(userLocation: here)
            state.haptics.success()
            dismiss()
        }
    }
}
