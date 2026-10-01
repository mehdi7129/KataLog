import Foundation

/// A local organizational label. Drone identity is independent of attribution.
public struct ClientProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String = UUID().uuidString, name: String) {
        self.id = id; self.name = name
    }
}

public struct ClientList: Codable, Sendable {
    public var clients: [ClientProfile]
    public init(clients: [ClientProfile] = []) { self.clients = clients }
}

public struct GeographicProximity: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var radiusMeters: Double
    public init(latitude: Double, longitude: Double, radiusMeters: Double) {
        self.latitude = latitude; self.longitude = longitude; self.radiusMeters = radiusMeters
    }
}
