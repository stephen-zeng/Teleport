import Foundation

struct SavedLocation: Identifiable, Equatable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var coordinate: LocationCoordinate
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        coordinate: LocationCoordinate,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.createdAt = createdAt
    }
}
