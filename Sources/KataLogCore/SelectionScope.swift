import CryptoKit
import Foundation

/// The same request is used by the library, views and exports. Calendar bounds
/// compare source calendar days; a path date is never assigned an invented zone.
public struct SelectionScope: Codable, Equatable, Sendable {
    public var logIDs: [String] = []
    public var droneKeys: [String] = []
    public var dateFrom: String? = nil
    public var dateTo: String? = nil
    public var includeUnknownDates = true
    public var families: [String] = []
    public var levels: [String] = []
    public var alertOnly = false
    public var search = ""
    public var logSearch = ""
    public var statuses: [String] = []
    public var includeMasked = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case logIDs, droneKeys, dateFrom, dateTo, includeUnknownDates, families, levels, alertOnly, search, logSearch, statuses, includeMasked
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logIDs = try c.decodeIfPresent([String].self, forKey: .logIDs) ?? []
        droneKeys = try c.decodeIfPresent([String].self, forKey: .droneKeys) ?? []
        dateFrom = try c.decodeIfPresent(String.self, forKey: .dateFrom)
        dateTo = try c.decodeIfPresent(String.self, forKey: .dateTo)
        includeUnknownDates = try c.decodeIfPresent(Bool.self, forKey: .includeUnknownDates) ?? true
        families = try c.decodeIfPresent([String].self, forKey: .families) ?? []
        levels = try c.decodeIfPresent([String].self, forKey: .levels) ?? []
        alertOnly = try c.decodeIfPresent(Bool.self, forKey: .alertOnly) ?? false
        search = try c.decodeIfPresent(String.self, forKey: .search) ?? ""
        logSearch = try c.decodeIfPresent(String.self, forKey: .logSearch) ?? ""
        statuses = try c.decodeIfPresent([String].self, forKey: .statuses) ?? []
        includeMasked = try c.decodeIfPresent(Bool.self, forKey: .includeMasked) ?? false
    }

    public static func normalizedSearch(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func calendarDay(_ value: String) -> String? {
        let day = String(value.prefix(10))
        guard day.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let expected = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: expected) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual == expected ? day : nil
    }

    public var hasMessageFilters: Bool {
        !families.isEmpty || !levels.isEmpty || alertOnly || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var isUnfiltered: Bool {
        logIDs.isEmpty && droneKeys.isEmpty && dateFrom == nil && dateTo == nil && includeUnknownDates &&
        !hasMessageFilters && logSearch.isEmpty && statuses.isEmpty
    }
    public var description: String {
        var parts: [String] = []
        if !logIDs.isEmpty { parts.append("\(logIDs.count) log(s)") }
        if !droneKeys.isEmpty { parts.append("\(droneKeys.count) identité(s)") }
        if dateFrom != nil || dateTo != nil { parts.append("\(dateFrom ?? "Sans borne de début") → \(dateTo ?? "Sans borne de fin") · dates source") }
        if !includeUnknownDates { parts.append("Dates inconnues exclues") }
        if !families.isEmpty { parts.append("Familles : " + families.joined(separator: ", ")) }
        if !levels.isEmpty { parts.append("Niveaux : " + levels.joined(separator: ", ")) }
        if alertOnly { parts.append("Alertes") }
        if !search.isEmpty { parts.append("Messages : « \(search) »") }
        if !logSearch.isEmpty { parts.append("Fichiers : « \(logSearch) »") }
        if !statuses.isEmpty { parts.append("Lecture : " + statuses.joined(separator: ", ")) }
        parts.append(includeMasked ? "Messages masqués inclus" : "Messages masqués exclus")
        return parts.joined(separator: " · ")
    }
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func applying(to source: FleetSnapshot, maskedMessageKeys: Set<String> = []) -> FleetSnapshot {
        let ids = Set(logIDs), drones = Set(droneKeys), familySet = Set(families), levelSet = Set(levels), statusSet = Set(statuses)
        let query = Self.normalizedSearch(search)
        let logQuery = Self.normalizedSearch(logSearch)
        var result = source
        result.logs = source.logs.compactMap { original in
            guard ids.isEmpty || ids.contains(original.id) else { return nil }
            guard drones.isEmpty || drones.contains(original.annotationKey) else { return nil }
            guard statusSet.isEmpty || statusSet.contains(original.status) else { return nil }
            if Self.calendarDay(original.date) == nil {
                guard includeUnknownDates else { return nil }
            } else if let day = Self.calendarDay(original.date) {
                if let dateFrom, day < dateFrom { return nil }
                if let dateTo, day > dateTo { return nil }
            }
            if !logQuery.isEmpty && !( [original.id, original.fileName, original.droneID, original.droneName, original.displayName] + original.sourcePaths )
                .contains(where: { Self.normalizedSearch($0).contains(logQuery) }) { return nil }
            var log = original
            log.messages = original.messages.compactMap { originalMessage in
                var message = originalMessage
                message.isMasked = maskedMessageKeys.contains(message.classificationKey) || message.isMasked == true
                guard includeMasked || message.isMasked != true else { return nil }
                guard familySet.isEmpty || familySet.contains(message.family) else { return nil }
                guard levelSet.isEmpty || levelSet.contains(message.level) else { return nil }
                guard !alertOnly || message.isAlert else { return nil }
                guard query.isEmpty || [message.text, message.title, message.family].contains(where: { Self.normalizedSearch($0).contains(query) }) else { return nil }
                return message
            }
            guard !hasMessageFilters || !log.messages.isEmpty else { return nil }
            log.selectionIncludesFailsafe = !hasMessageFilters
            log.selectionIncludesEvents = !hasMessageFilters
            if !includeMasked && original.messages.contains(where: {
                ($0.isMasked == true || maskedMessageKeys.contains($0.classificationKey)) &&
                $0.text.range(of: #"\bfailsafe activated\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            }) { log.selectionIncludesFailsafe = false }
            log.summaryMessageCount = log.messages.count
            log.summaryAlertMessageCount = log.messages.filter(\.isAlert).count
            log.summaryHasAlerts = log.summaryAlertMessageCount! > 0
            // A projection badge belongs to its original message selection.
            // Recompute after filtering/masking to avoid retaining a hidden signal.
            if hasMessageFilters || log.messages.count != original.messages.count {
                log.signalAssessment = nil
                log.signalAssessment = log.inferredAssessment
            }
            return log
        }
        return result
    }
}

public struct SavedLibraryView: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var scope: SelectionScope
    public init(id: String = UUID().uuidString, name: String, scope: SelectionScope) {
        self.id = id; self.name = name; self.scope = scope
    }
}

public struct LibraryViewState: Codable, Sendable {
    public var schemaVersion = 1
    public var revision = 0
    public var activeScope = SelectionScope()
    public var views: [SavedLibraryView] = []
    public var maskedMessageKeys: [String] = []
    public var theme: String? = nil
    public var profileAxes: [String]? = nil
    public var studyPreferences: [String: TelemetryRequest]? = nil
    public var historySort: String? = nil
    public init() {}
}
