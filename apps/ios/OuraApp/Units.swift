import Foundation
import SwiftUI

/// Display units, chosen by the user and defaulting to the iPhone's region.
/// Everything is stored and computed in metric; conversion happens only on screen.
enum HeightUnit: String, CaseIterable, Identifiable {
    case centimeters, meters, feetInches
    var id: String { rawValue }
    var label: String {
        switch self {
        case .centimeters: return "cm"
        case .meters: return "m"
        case .feetInches: return "ft & in"
        }
    }
}

enum WeightUnit: String, CaseIterable, Identifiable {
    case kilograms, pounds, stonesPounds
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kilograms: return "kg"
        case .pounds: return "lb"
        case .stonesPounds: return "st & lb"
        }
    }
}

enum TemperatureUnit: String, CaseIterable, Identifiable {
    case celsius, fahrenheit
    var id: String { rawValue }
    var symbol: String { self == .celsius ? "°C" : "°F" }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case kilometers, miles
    var id: String { rawValue }
    var symbol: String { self == .kilometers ? "km" : "mi" }
}

final class UnitSettings: ObservableObject {
    static let shared = UnitSettings()

    @Published var height: HeightUnit { didSet { save(height.rawValue, "units.height") } }
    @Published var weight: WeightUnit { didSet { save(weight.rawValue, "units.weight") } }
    @Published var temperature: TemperatureUnit { didSet { save(temperature.rawValue, "units.temperature") } }
    @Published var distance: DistanceUnit { didSet { save(distance.rawValue, "units.distance") } }

    private init() {
        let d = UserDefaults.standard
        let system = Locale.current.measurementSystem
        let us = system == .us
        let uk = system == .uk
        height = d.string(forKey: "units.height").flatMap(HeightUnit.init) ?? (us || uk ? .feetInches : .centimeters)
        weight = d.string(forKey: "units.weight").flatMap(WeightUnit.init) ?? (us ? .pounds : uk ? .stonesPounds : .kilograms)
        temperature = d.string(forKey: "units.temperature").flatMap(TemperatureUnit.init) ?? (us ? .fahrenheit : .celsius)
        distance = d.string(forKey: "units.distance").flatMap(DistanceUnit.init) ?? (us || uk ? .miles : .kilometers)
    }

    private func save(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

enum Convert {
    static let cmPerInch = 2.54
    static let kgPerPound = 0.45359237
    static let poundsPerStone = 14.0
    static let metersPerMile = 1609.344

    // MARK: Temperature

    /// An absolute temperature in the chosen unit.
    static func temperature(_ celsius: Double, _ unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// A temperature *difference* (deviation from baseline) in the chosen unit.
    static func temperatureDelta(_ celsius: Double, _ unit: TemperatureUnit) -> Double {
        unit == .celsius ? celsius : celsius * 9 / 5
    }

    // MARK: Distance

    static func distance(meters: Double, _ unit: DistanceUnit) -> Double {
        unit == .kilometers ? meters / 1000 : meters / metersPerMile
    }

    // MARK: Height and weight

    /// Whole feet and the remaining inches (one decimal place) for a height in cm.
    static func feetInches(cm: Double) -> (feet: Int, inches: Double) {
        let totalInches = cm / cmPerInch
        var feet = Int(totalInches / 12)
        var inches = ((totalInches - Double(feet) * 12) * 10).rounded() / 10
        if inches >= 12 { feet += 1; inches -= 12 }
        return (feet, inches)
    }

    static func cm(feet: Double, inches: Double) -> Double {
        (feet * 12 + inches) * cmPerInch
    }

    static func pounds(kg: Double) -> Double { kg / kgPerPound }
    static func kg(pounds: Double) -> Double { pounds * kgPerPound }

    /// Whole stones and the remaining pounds (one decimal place) for a weight in kg.
    static func stonesPounds(kg: Double) -> (stones: Int, pounds: Double) {
        let totalPounds = pounds(kg: kg)
        var stones = Int(totalPounds / poundsPerStone)
        var rest = ((totalPounds - Double(stones) * poundsPerStone) * 10).rounded() / 10
        if rest >= poundsPerStone { stones += 1; rest -= poundsPerStone }
        return (stones, rest)
    }

    static func kg(stones: Double, pounds rest: Double) -> Double {
        kg(pounds: stones * poundsPerStone + rest)
    }
}

extension Fmt {
    /// "34.4 °C" / "93.9 °F" with one decimal.
    static func temperature(_ celsius: Double?, _ unit: TemperatureUnit) -> String {
        guard let celsius else { return "–" }
        return String(format: "%.1f", Convert.temperature(celsius, unit))
    }

    /// "+0.3" style deviation in the chosen unit, two decimals for °C deltas.
    static func temperatureDelta(_ celsius: Double?, _ unit: TemperatureUnit) -> String {
        guard let celsius else { return "–" }
        return String(format: "%+.1f", Convert.temperatureDelta(celsius, unit))
    }

    static func distance(meters: Double?, _ unit: DistanceUnit) -> String {
        guard let meters else { return "–" }
        return String(format: "%.2f", Convert.distance(meters: meters, unit))
    }

    static func height(cm: Double, _ unit: HeightUnit) -> String {
        switch unit {
        case .centimeters: return String(format: "%.1f cm", cm)
        case .meters: return String(format: "%.2f m", cm / 100)
        case .feetInches:
            let fi = Convert.feetInches(cm: cm)
            return "\(fi.feet) ft \(String(format: "%.1f", fi.inches)) in"
        }
    }

    static func weight(kg: Double, _ unit: WeightUnit) -> String {
        switch unit {
        case .kilograms: return String(format: "%.1f kg", kg)
        case .pounds: return String(format: "%.1f lb", Convert.pounds(kg: kg))
        case .stonesPounds:
            let sp = Convert.stonesPounds(kg: kg)
            return "\(sp.stones) st \(String(format: "%.1f", sp.pounds)) lb"
        }
    }
}

/// Height entry in the chosen unit, bound to a value stored in centimetres.
struct HeightField: View {
    @Binding var cm: Double
    let unit: HeightUnit

    var body: some View {
        switch unit {
        case .centimeters:
            numberRow("Height", unitLabel: "cm", value: $cm)
        case .meters:
            numberRow("Height", unitLabel: "m", value: Binding(
                get: { cm / 100 }, set: { cm = $0 * 100 }))
        case .feetInches:
            HStack {
                Text("Height")
                Spacer()
                TextField("ft", value: Binding(
                    get: { Double(Convert.feetInches(cm: cm).feet) },
                    set: { cm = Convert.cm(feet: $0, inches: Convert.feetInches(cm: cm).inches) }),
                    format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 44)
                Text("ft").foregroundStyle(.secondary)
                TextField("in", value: Binding(
                    get: { Convert.feetInches(cm: cm).inches },
                    set: { cm = Convert.cm(feet: Double(Convert.feetInches(cm: cm).feet), inches: $0) }),
                    format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 56)
                Text("in").foregroundStyle(.secondary)
            }
        }
    }
}

/// Weight entry in the chosen unit, bound to a value stored in kilograms.
struct WeightField: View {
    @Binding var kg: Double
    let unit: WeightUnit

    var body: some View {
        switch unit {
        case .kilograms:
            numberRow("Weight", unitLabel: "kg", value: $kg)
        case .pounds:
            numberRow("Weight", unitLabel: "lb", value: Binding(
                get: { Convert.pounds(kg: kg) }, set: { kg = Convert.kg(pounds: $0) }))
        case .stonesPounds:
            HStack {
                Text("Weight")
                Spacer()
                TextField("st", value: Binding(
                    get: { Double(Convert.stonesPounds(kg: kg).stones) },
                    set: { kg = Convert.kg(stones: $0, pounds: Convert.stonesPounds(kg: kg).pounds) }),
                    format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 44)
                Text("st").foregroundStyle(.secondary)
                TextField("lb", value: Binding(
                    get: { Convert.stonesPounds(kg: kg).pounds },
                    set: { kg = Convert.kg(stones: Double(Convert.stonesPounds(kg: kg).stones), pounds: $0) }),
                    format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 56)
                Text("lb").foregroundStyle(.secondary)
            }
        }
    }
}

private func numberRow(_ title: String, unitLabel: String, value: Binding<Double>) -> some View {
    HStack {
        Text(title)
        Spacer()
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
        Text(unitLabel).foregroundStyle(.secondary)
    }
}
