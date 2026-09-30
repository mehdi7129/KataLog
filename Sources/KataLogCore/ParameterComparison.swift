import Foundation

public struct ParameterDifference: Sendable, Identifiable {
    public enum Change: String, Sendable { case added, absent, value, type }
    public let name: String
    public let change: Change
    public let before: JSONValue?
    public let after: JSONValue?
    public let beforeType: String?
    public let afterType: String?
    public var id: String { name }
}

public struct ParameterComparison: Sendable {
    public let comparable: Bool
    public let explanation: String
    public let differences: [ParameterDifference]
    public let previousFirmware: String?
    public let currentFirmware: String?
    public var firmwareDiffers: Bool {
        previousFirmware != nil && currentFirmware != nil && previousFirmware != currentFirmware
    }
    /// Compare final recorded parameter values. Missing extraction never means
    /// that every parameter was removed from a vehicle.
    public static func compare(previous: FlightLog, current: FlightLog) -> Self {
        let oldFirmware = firmware(previous), newFirmware = firmware(current)
        guard previous.droneID == current.droneID else {
            return Self(comparable: false, explanation: "Les analyses concernent des contrôleurs distincts.", differences: [], previousFirmware: oldFirmware, currentFirmware: newFirmware)
        }
        guard let before = values(previous.parameterDetails), let after = values(current.parameterDetails) else {
            return Self(comparable: false, explanation: "Paramètres typés non extraits dans au moins une analyse. Leur absence ne prouve pas leur suppression.", differences: [], previousFirmware: oldFirmware, currentFirmware: newFirmware)
        }
        var differences: [ParameterDifference] = []
        for name in Set(before.keys).union(after.keys).sorted() {
            let old = before[name], new = after[name]
            let change: ParameterDifference.Change?
            if old == nil { change = .added }
            else if new == nil { change = .absent }
            else if old?.type != new?.type { change = .type }
            else if old?.value != new?.value { change = .value }
            else { change = nil }
            if let change { differences.append(.init(name: name, change: change, before: old?.value, after: new?.value, beforeType: old?.type, afterType: new?.type)) }
        }
        return Self(comparable: true, explanation: "Valeurs finales enregistrées, types décodés par pyulog. Un écart entre analyses ne prouve ni modification physique ni cause d’une alerte.", differences: differences, previousFirmware: oldFirmware, currentFirmware: newFirmware)
    }
    private struct Value { let value: JSONValue; let type: String }
    private static func values(_ details: JSONValue?) -> [String: Value]? {
        guard let details, details["schemaVersion"] == 1,
              case .array(let initial) = details["initial"],
              case .array(let changes) = details["changes"] else { return nil }
        var result: [String: Value] = [:]
        for entry in initial + changes {
            guard let name = entry["name"]?.stringValue, let type = entry["type"]?.stringValue, let value = entry["value"] else { return nil }
            result[name] = Value(value: value, type: type)
        }
        return result
    }
    private static func firmware(_ log: FlightLog) -> String? {
        if let value = log.metadata["firmware"], !value.isEmpty, value != "Inconnu" { return value }
        return log.metadata["ver_sw"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
