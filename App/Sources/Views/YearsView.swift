import SwiftUI
import YearBarcodeCore

struct YearsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var selectedYear: Int?
    @State private var settings = ArtworkSettings.default
    @State private var isGenerating = false

    var body: some View {
        Form {
            if model.authorization == .limited {
                Section {
                    Label {
                        Text("Limited photo access: only the photos you allowed will be included.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Button("Change in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            }

            Section("Year") {
                if model.isLoadingYears && model.years.isEmpty {
                    ProgressView()
                } else if model.years.isEmpty {
                    Text("No dated photos found.").foregroundStyle(.secondary)
                } else {
                    Picker("Year", selection: $selectedYear) {
                        ForEach(model.years, id: \.self) { Text(String($0)).tag(Optional($0)) }
                    }
                }
            }

            Section {
                Picker("Mode", selection: $settings.mode) {
                    ForEach(BarcodeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settings.mode.helpText).font(.footnote).foregroundStyle(.secondary)
                Picker("Orientation", selection: $settings.orientation) {
                    ForEach(Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Print size", selection: $settings.printSize) {
                    ForEach(PrintSize.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Artwork")
            } footer: {
                Text("You can change mode, size, and orientation later without re-analyzing.")
            }

            Section {
                Button {
                    guard let year = selectedYear else { return }
                    isGenerating = true
                    Task {
                        await model.generate(year: year, settings: settings)
                        isGenerating = false
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isGenerating { ProgressView() } else { Text("Generate").bold() }
                        Spacer()
                    }
                }
                .disabled(selectedYear == nil || isGenerating)
            } footer: {
                Text("Generate freezes which photos belong to this artwork. Photos taken or imported afterwards are not added.")
            }

            if !model.generations.isEmpty {
                Section("Saved") {
                    ForEach(model.generations) { record in
                        NavigationLink(value: record.status == .finished ? Route.artwork(record.id) : Route.progress(record.id)) {
                            SavedRow(record: record)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.delete(model.generations[index].id) }
                    }
                }
            }
        }
        .navigationTitle("Year Barcode")
        .refreshable { await model.refreshYears() }
        .onChange(of: model.years, initial: true) { _, years in
            if selectedYear == nil || !(years.contains(selectedYear!)) { selectedYear = years.first }
        }
    }
}

private struct SavedRow: View {
    let record: GenerationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(record.year)).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        let created = record.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch record.status {
        case .finished: return "Created \(created)"
        case .analyzing: return "Analyzing…"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted - tap to resume"
        case .cancelled: return "Cancelled"
        }
    }
}
