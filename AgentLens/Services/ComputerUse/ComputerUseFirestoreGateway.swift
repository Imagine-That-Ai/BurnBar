#if canImport(AppKit)
import CoreFoundation
import FirebaseFirestore
import Foundation

struct ComputerUseFirestorePayload: Sendable {
    enum Value: Sendable {
        case bool(Bool)
        case data(Data)
        case date(Date)
        case double(Double)
        case integer(Int64)
        case string(String)
        case timestamp(Date)

        init?(firestoreValue: Any) {
            switch firestoreValue {
            case let value as NSNumber:
                if CFGetTypeID(value) == CFBooleanGetTypeID() {
                    self = .bool(value.boolValue)
                } else if ["f", "d"].contains(String(cString: value.objCType)) {
                    self = .double(value.doubleValue)
                } else {
                    self = .integer(value.int64Value)
                }
            case let value as Bool:
                self = .bool(value)
            case let value as Data:
                self = .data(value)
            case let value as Timestamp:
                self = .timestamp(value.dateValue())
            case let value as Date:
                self = .date(value)
            case let value as String:
                self = .string(value)
            case let value as Int:
                self = .integer(Int64(value))
            case let value as Int64:
                self = .integer(value)
            case let value as Double:
                self = .double(value)
            case let value as Float:
                self = .double(Double(value))
            default:
                return nil
            }
        }

        var firestoreValue: Any {
            switch self {
            case let .bool(value): value
            case let .data(value): value
            case let .date(value): value
            case let .double(value): value
            case let .integer(value): value
            case let .string(value): value
            case let .timestamp(value): Timestamp(date: value)
            }
        }
    }

    private var values: [String: Value]

    init(values: [String: Value]) {
        self.values = values
    }

    init(snapshotData: [String: Any]) {
        self.values = snapshotData.compactMapValues(Value.init(firestoreValue:))
    }

    var firestoreData: [String: Any] {
        values.mapValues(\.firestoreValue)
    }

    var keys: Set<String> {
        Set(values.keys)
    }

    func contains(_ key: String) -> Bool {
        values[key] != nil
    }

    func bool(_ key: String) -> Bool? {
        guard case let .bool(value) = values[key] else { return nil }
        return value
    }

    func date(_ key: String) -> Date? {
        switch values[key] {
        case let .date(value), let .timestamp(value): value
        case let .double(value): Date(timeIntervalSince1970: value)
        case let .integer(value): Date(timeIntervalSince1970: TimeInterval(value))
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch values[key] {
        case let .double(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        guard case let .integer(value) = values[key] else { return nil }
        return Int(exactly: value)
    }

    func string(_ key: String) -> String? {
        guard case let .string(value) = values[key] else { return nil }
        return value
    }

    func containsStringFragment(_ fragment: String) -> Bool {
        values.values.contains { value in
            guard case let .string(string) = value else { return false }
            return string.contains(fragment)
        }
    }

    mutating func setString(_ value: String, forKey key: String) {
        values[key] = .string(value)
    }
}

struct ComputerUseFirestoreDocumentSnapshot: Sendable {
    let exists: Bool
    let payload: ComputerUseFirestorePayload?
    let isFromCache: Bool
}

protocol ComputerUseFirestoreListenerRegistration: AnyObject {
    func remove()
}

protocol ComputerUseFirestoreGateway: AnyObject, Sendable {
    func addSnapshotListener(
        at documentPath: String,
        handler: @escaping @Sendable (ComputerUseFirestoreDocumentSnapshot?, Error?) -> Void
    ) -> any ComputerUseFirestoreListenerRegistration

    func getDocumentFromServer(at documentPath: String) async throws -> ComputerUseFirestoreDocumentSnapshot

    func setData(
        _ payload: ComputerUseFirestorePayload,
        at documentPath: String,
        merge: Bool
    ) async throws
}

/// The only Computer Use adapter allowed to resolve the Firebase singleton.
/// Domain services depend on `ComputerUseFirestoreGateway`, which keeps tests
/// deterministic and prevents Firestore handles from spreading through runtime ownership.
final class ComputerUseFirestoreLiveGateway: ComputerUseFirestoreGateway {
    private let firestoreProvider: @Sendable () -> Firestore

    init(firestoreProvider: @escaping @Sendable () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func addSnapshotListener(
        at documentPath: String,
        handler: @escaping @Sendable (ComputerUseFirestoreDocumentSnapshot?, Error?) -> Void
    ) -> any ComputerUseFirestoreListenerRegistration {
        let registration = firestoreProvider()
            .document(documentPath)
            .addSnapshotListener { snapshot, error in
                handler(snapshot.map(Self.snapshot), error)
            }
        return ComputerUseFirestoreLiveListenerRegistration(registration: registration)
    }

    func getDocumentFromServer(at documentPath: String) async throws -> ComputerUseFirestoreDocumentSnapshot {
        let snapshot = try await firestoreProvider()
            .document(documentPath)
            .getDocument(source: .server)
        return Self.snapshot(snapshot)
    }

    func setData(
        _ payload: ComputerUseFirestorePayload,
        at documentPath: String,
        merge: Bool
    ) async throws {
        try await firestoreProvider()
            .document(documentPath)
            .setData(payload.firestoreData, merge: merge)
    }

    private static func snapshot(_ snapshot: DocumentSnapshot) -> ComputerUseFirestoreDocumentSnapshot {
        ComputerUseFirestoreDocumentSnapshot(
            exists: snapshot.exists,
            payload: snapshot.data().map(ComputerUseFirestorePayload.init(snapshotData:)),
            isFromCache: snapshot.metadata.isFromCache
        )
    }
}

private final class ComputerUseFirestoreLiveListenerRegistration: ComputerUseFirestoreListenerRegistration {
    private let registration: ListenerRegistration

    init(registration: ListenerRegistration) {
        self.registration = registration
    }

    func remove() {
        registration.remove()
    }
}
#endif
