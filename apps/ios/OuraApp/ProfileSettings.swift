import SwiftUI
import HealthKit
import UniformTypeIdentifiers

private struct EditableProfile {
    var sex: String
    var age: Double
    var heightCm: Double
    var weightKg: Double
    var ringSize: Double

    init(_ profile: Profile?) {
        sex = profile?.sex ?? "M"
        age = profile?.age ?? 30
        heightCm = (profile?.height_m ?? 1.78) * 100
        weightKg = profile?.weight_kg ?? 75
        ringSize = profile?.ring_size ?? 10
    }
}

private enum ProfileStore {
    static var url: URL { DB.url.deletingLastPathComponent().appendingPathComponent("profile.json") }

    static func save(_ p: EditableProfile) throws {
        let object: [String: Any] = [
            "sex": p.sex, "age": p.age, "height_m": p.heightCm / 100,
            "weight_kg": p.weightKg, "ring_size": p.ringSize,
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private struct HealthProfile {
    var sex: String?
    var age: Double?
    var heightCm: Double?
    var weightKg: Double?
}

private enum HealthProfileImporter {
    static func load(completion: @escaping (Result<HealthProfile, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(.failure(NSError(domain: "open_oura", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Apple Health is unavailable on this device."])))
            return
        }
        let store = HKHealthStore()
        let dob = HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!
        let biologicalSex = HKObjectType.characteristicType(forIdentifier: .biologicalSex)!
        let height = HKObjectType.quantityType(forIdentifier: .height)!
        let mass = HKObjectType.quantityType(forIdentifier: .bodyMass)!
        let read: Set<HKObjectType> = [dob, biologicalSex, height, mass]
        store.requestAuthorization(toShare: [], read: read) { granted, error in
            if let error { DispatchQueue.main.async { completion(.failure(error)) }; return }
            guard granted else {
                let e = NSError(domain: "open_oura", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Apple Health access was not granted."])
                DispatchQueue.main.async { completion(.failure(e)) }
                return
            }

            var result = HealthProfile()
            if let birth = try? store.dateOfBirthComponents().date {
                result.age = Double(Calendar.current.dateComponents([.year], from: birth, to: Date()).year ?? 0)
            }
            if let value = try? store.biologicalSex().biologicalSex {
                switch value {
                case .female: result.sex = "F"
                case .male: result.sex = "M"
                case .other: result.sex = "O"
                default: break
                }
            }

            let group = DispatchGroup()
            func latest(_ type: HKQuantityType, unit: HKUnit, assign: @escaping (Double) -> Void) {
                group.enter()
                let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
                let query = HKSampleQuery(sampleType: type, predicate: nil, limit: 1,
                                          sortDescriptors: [sort]) { _, samples, _ in
                    if let sample = samples?.first as? HKQuantitySample {
                        assign(sample.quantity.doubleValue(for: unit))
                    }
                    group.leave()
                }
                store.execute(query)
            }
            latest(height, unit: .meterUnit(with: .centi)) { result.heightCm = $0 }
            latest(mass, unit: .gramUnit(with: .kilo)) { result.weightKg = $0 }
            group.notify(queue: .main) { completion(.success(result)) }
        }
    }
}

struct ProfileSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EditableProfile
    @State private var importing = false
    @State private var message: String?
    @ObservedObject private var health = HealthExport.shared
    @ObservedObject private var units = UnitSettings.shared
    @State private var ouraImport: OuraImportInfo?
    @State private var choosingExport = false
    @State private var importStatus: String?
    @State private var importingExport = false
    let onSaved: () -> Void

    init(profile: Profile?, ouraImport: OuraImportInfo? = nil, onSaved: @escaping () -> Void) {
        _profile = State(initialValue: EditableProfile(profile))
        _ouraImport = State(initialValue: ouraImport)
        self.onSaved = onSaved
    }

    private func importExport(_ url: URL) {
        importingExport = true
        importStatus = nil
        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            let json = text.map { importOuraExport(dbPath: DB.url.path, csvText: $0) }
            let object = json.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            await MainActor.run {
                importingExport = false
                guard let object else {
                    importStatus = "Couldn't read that file."
                    return
                }
                if let error = object["error"] as? String {
                    importStatus = "Not imported: \(error)"
                    return
                }
                let calibrated = object["calibrated"] as? [String: Any]
                let info = OuraImportInfo(
                    days: object["days"] as? Int, first: object["first"] as? String,
                    last: object["last"] as? String,
                    calibrated: .init(sleep: calibrated?["sleep"] as? Bool,
                                      readiness: calibrated?["readiness"] as? Bool))
                ouraImport = info
                importStatus = "Imported \(info.days ?? 0) days."
                onSaved()
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Biological sex", selection: $profile.sex) {
                        Text("Female").tag("F")
                        Text("Male").tag("M")
                        Text("Other").tag("O")
                    }
                    TextField("Age", value: $profile.age, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                    HeightField(cm: $profile.heightCm, unit: units.height)
                    WeightField(kg: $profile.weightKg, unit: units.weight)
                    TextField("Ring size", value: $profile.ringSize, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Stored only on this iPhone and used by the cardiovascular and activity calculations.")
                }

                Section {
                    Picker("Height", selection: $units.height) {
                        ForEach(HeightUnit.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Weight", selection: $units.weight) {
                        ForEach(WeightUnit.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Temperature", selection: $units.temperature) {
                        ForEach(TemperatureUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                    Picker("Distance", selection: $units.distance) {
                        ForEach(DistanceUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                } header: {
                    Text("Units")
                } footer: {
                    Text("Changes how values are shown. Your data is unaffected.")
                }

                Section {
                    Button {
                        importing = true; message = nil
                        HealthProfileImporter.load { result in
                            importing = false
                            switch result {
                            case .success(let health):
                                if let v = health.sex { profile.sex = v }
                                if let v = health.age, v > 0 { profile.age = v }
                                if let v = health.heightCm { profile.heightCm = v }
                                if let v = health.weightKg { profile.weightKg = v }
                                message = "Imported available values from Apple Health."
                            case .failure(let error): message = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Label("Import from Apple Health", systemImage: "heart.text.square")
                            Spacer()
                            if importing { ProgressView() }
                        }
                    }
                    .disabled(importing)
                    if let message { Text(message).font(.footnote).foregroundStyle(Obs.ink2) }
                }

                Section {
                    if let info = ouraImport {
                        LabeledContent("Days imported", value: "\(info.days ?? 0)")
                        LabeledContent("Covers", value: "\(Fmt.day(info.first)) – \(Fmt.day(info.last))")
                        LabeledContent("Scores calibrated", value: calibrationText(info))
                    }
                    Button {
                        choosingExport = true
                    } label: {
                        HStack {
                            Label(ouraImport == nil ? "Import Oura export" : "Replace with a newer export",
                                  systemImage: "square.and.arrow.down")
                            Spacer()
                            if importingExport { ProgressView() }
                        }
                    }
                    .disabled(importingExport)
                    if ouraImport != nil {
                        Button("Remove imported data", role: .destructive) {
                            _ = clearOuraExport(dbPath: DB.url.path)
                            ouraImport = nil
                            importStatus = nil
                            onSaved()
                        }
                    }
                    if let importStatus {
                        Text(importStatus).font(.footnote).foregroundStyle(Obs.ink2)
                    }
                } header: {
                    Text("Oura history")
                } footer: {
                    Text("Import the trends CSV from your Oura account to fit Readiness and Sleep to Oura's own scale and to see your history from before this app. It stays on this iPhone.")
                }
                .fileImporter(isPresented: $choosingExport,
                              allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data]) { result in
                    if case .success(let url) = result { importExport(url) }
                }

                Section {
                    Toggle("Write ring data to Apple Health", isOn: Binding(
                        get: { health.enabled },
                        set: { health.setEnabled($0, summary: SummaryCache.load()) }
                    ))
                    if !health.status.isEmpty {
                        Text(health.status).font(.footnote).foregroundStyle(Obs.ink2)
                    }
                    if health.enabled {
                        Button("Remove Open Oura samples from Health") {
                            health.removeExportedSamples()
                        }
                        .foregroundStyle(Obs.bad)
                    }
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Exports workouts (and removes ones the ring no longer detects), sleep stages, heart rate, HRV, resting HR, steps, active calories, and distance. Data stays on this iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Obs.canvas.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try ProfileStore.save(profile)
                            onSaved()
                            dismiss()
                        } catch { message = "Could not save: \(error.localizedDescription)" }
                    }
                }
            }
        }
    }
}

private func calibrationText(_ info: OuraImportInfo) -> String {
    switch (info.calibrated?.sleep == true, info.calibrated?.readiness == true) {
    case (true, true): return "Sleep & Readiness"
    case (true, false): return "Sleep"
    case (false, true): return "Readiness"
    default: return "Not enough data"
    }
}
