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
    /// Shown on the Sleep screen next to the Oura-scale score only when this is on.
    @AppStorage("sleep.showNormsScore") private var showNormsScore = false
    @Environment(\.dismiss) private var dismiss
    @State private var profile: EditableProfile
    @State private var importing = false
    @State private var message: String?
    @ObservedObject private var health = HealthExport.shared
    @ObservedObject private var units = UnitSettings.shared
    @State private var ouraImport: OuraImportInfo?
    @State private var measureBloodOxygen = BloodOxygen.wanted
    @State private var choosingExport = false
    @State private var importStatus: String?
    @State private var importingExport = false
    let onSaved: () -> Void

    init(profile: Profile?, ouraImport: OuraImportInfo? = nil, onSaved: @escaping () -> Void) {
        _profile = State(initialValue: EditableProfile(profile))
        _ouraImport = State(initialValue: ouraImport)
        self.onSaved = onSaved
    }

    /// Export files the importer uses; everything else in Oura's export (raw
    /// location, motion, heart rate…) is left unread, some of it is hundreds of MB.
    private static let wantedExportFiles = ["dailysleep", "dailyreadiness", "sleepmodel",
                                            "dailyactivity", "dailyspo2", "dailystress",
                                            "daytimestress", "dailyresilience", "dailycardiovascularage", "trends"]

    /// The CSVs to read from what was picked: files directly, or the wanted ones
    /// inside a picked folder (the unzipped export).
    private static func exportFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
                while let item = items?.nextObject() as? URL {
                    if item.pathExtension.lowercased() == "csv" { out.append(item) }
                }
            } else {
                out.append(url)
            }
        }
        if out.count == 1 { return out }
        return out.filter { url in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            return wantedExportFiles.contains { name.contains($0) }
        }
    }

    /// The app's own folder in the Files app (On My iPhone → Open Oura → Oura export).
    /// Files copied there are read directly, with no document picker involved.
    static var dropFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Oura export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Import whatever export files are in the app's own Files folder (any subfolder).
    private func importFromDropFolder() {
        _ = Self.dropFolder
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        importExport([docs])
    }

    private func importExport(_ urls: [URL]) {
        importingExport = true
        importStatus = nil
        Task.detached(priority: .userInitiated) {
            let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, ok) in scoped where ok { url.stopAccessingSecurityScopedResource() } }
            let files: [[String: String]] = Self.exportFiles(in: urls).compactMap { url in
                guard let text = (try? String(contentsOf: url, encoding: .utf8))
                        ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return nil }
                return ["name": url.lastPathComponent, "text": text]
            }
            let list = (try? JSONSerialization.data(withJSONObject: files)).flatMap { String(data: $0, encoding: .utf8) }
            let json = files.isEmpty ? nil : list.map { importOuraExportFiles(dbPath: DB.url.path, filesJson: $0) }
            let object = json.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            await MainActor.run {
                importingExport = false
                guard let object else {
                    importStatus = files.isEmpty ? "No Oura export files found in what you picked." : "Couldn't read those files."
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
                let both = (calibrated?["sleep"] as? Bool ?? false) && (calibrated?["readiness"] as? Bool ?? false)
                importStatus = "Imported \(info.days ?? 0) days" + (both ? ". Sleep and Readiness are now on Oura's scale." : ".")
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
                    LabeledContent("Age") {
                        TextField("Age", value: $profile.age, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    HeightField(cm: $profile.heightCm, unit: units.height)
                    WeightField(kg: $profile.weightKg, unit: units.weight)
                    LabeledContent("Ring size") {
                        TextField("Ring size", value: $profile.ringSize, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
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
                    if let message { Text(message).font(Obs.mono(13)).foregroundStyle(Obs.ink2) }
                }

                Section {
                    Toggle("Measure blood oxygen during sleep", isOn: $measureBloodOxygen)
                        .onChange(of: measureBloodOxygen) { _, on in BloodOxygen.wanted = on }
                } header: {
                    Text("Ring")
                } footer: {
                    Text(BloodOxygen.pendingChange == nil
                         ? "The ring measures blood oxygen overnight. It uses a little more ring battery."
                         : "Applied to your ring at the next sync. The ring measures blood oxygen overnight, using a little more ring battery.")
                }

                Section {
                    if let info = ouraImport {
                        Toggle("Also show the sleep-norms score", isOn: $showNormsScore)
                        LabeledContent("Days imported", value: "\(info.days ?? 0)")
                        LabeledContent("Covers", value: "\(Fmt.day(info.first)) – \(Fmt.day(info.last))")
                        LabeledContent("Scores calibrated", value: calibrationText(info))
                    }
                    Button {
                        importFromDropFolder()
                    } label: {
                        HStack {
                            Label("Import from the Open Oura folder", systemImage: "folder")
                            Spacer()
                            if importingExport { ProgressView() }
                        }
                    }
                    .disabled(importingExport)
                    Button {
                        choosingExport = true
                    } label: {
                        Label(ouraImport == nil ? "Pick files to import…" : "Pick newer files to import…",
                              systemImage: "square.and.arrow.down")
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
                        Text(importStatus).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
                    }
                } header: {
                    Text("Oura history")
                } footer: {
                    Text("In the Files app, copy dailysleep, dailyreadiness, sleepmodel, dailyactivity, dailyspo2, dailystress, daytimestress, dailyresilience and dailycardiovascularage from your unzipped Oura export into On My iPhone → Open Oura → Oura export, then tap Import from the Open Oura folder (an older trends CSV works too). This fits Readiness, Sleep and Stress to Oura's own scale and adds your history from before this app. It stays on this iPhone.")
                }
                .fileImporter(isPresented: $choosingExport,
                              // No `.folder` here: with it, iOS's picker only lets folders be chosen.
                              allowedContentTypes: [.commaSeparatedText, .plainText, .text, .data],
                              allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result, !urls.isEmpty { importExport(urls) }
                }

                Section {
                    Toggle("Write ring data to Apple Health", isOn: Binding(
                        get: { health.enabled },
                        set: { health.setEnabled($0, summary: SummaryCache.load()) }
                    ))
                    if !health.status.isEmpty {
                        Text(health.status).font(Obs.mono(13)).foregroundStyle(Obs.ink2)
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
