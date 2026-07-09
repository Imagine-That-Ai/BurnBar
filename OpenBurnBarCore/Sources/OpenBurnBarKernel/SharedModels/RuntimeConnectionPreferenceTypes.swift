import Foundation

public enum RuntimeConnectionPreferenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case hermes
    case piAgent
}

public struct RuntimeConnectionPreferenceDoc: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var deviceID: String
    public var runtimeKind: RuntimeConnectionPreferenceKind
    public var selectedConnectionID: String
    public var selectedInstanceID: String?
    public var selectedModelID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var schemaVersion: Int

    public init(
        id: String? = nil,
        deviceID: String,
        runtimeKind: RuntimeConnectionPreferenceKind,
        selectedConnectionID: String,
        selectedInstanceID: String? = nil,
        selectedModelID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = 1
    ) {
        self.id = id ?? "\(deviceID)_\(runtimeKind.rawValue)"
        self.deviceID = deviceID
        self.runtimeKind = runtimeKind
        self.selectedConnectionID = selectedConnectionID
        self.selectedInstanceID = selectedInstanceID
        self.selectedModelID = selectedModelID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}
