import Foundation

// MARK: - Per-agent persona seats
//
// A persona is per *agent*, exactly like the model selection beside it: the
// voice you want from a fast local CLI is rarely the voice you want from a
// reasoning gateway, and having one global persona would force a re-pick on
// every agent switch.
//
// Storage deliberately differs from `chatModelSelection(for:)`, which spends
// twelve stored properties and twelve `UserDefaults` keys on the same idea.
// Personas are a sparse map — most agents will never have one — so they persist
// as a single JSON blob, following the `ElderWandSettings.presets` convention.

extension ChatSessionController {
    static let udPersonaSeats = "chatPanel.personaSeats.v1"
    static let udPersonaRoster = "chatPanel.personaRoster.v1"

    /// The seat chosen for `backend`, or `nil` when that agent speaks in its own
    /// default voice.
    func personaSeatID(for backend: ChatBackendID) -> String? {
        personaSeatsByBackend[backend.rawValue]
    }

    /// Picks a seat for `backend`. Passing `nil` clears the voice, which is a
    /// real choice and not a missing value — "no persona" is how you get the
    /// model's own register back.
    func setPersonaSeatID(_ seatID: String?, for backend: ChatBackendID) {
        if let seatID, seatID != PlasmaSeat.neutralID {
            personaSeatsByBackend[backend.rawValue] = seatID
        } else {
            personaSeatsByBackend.removeValue(forKey: backend.rawValue)
        }
        persistPersonaSeats()
    }

    /// The persona whose voice will prefix the next send on `backend`.
    ///
    /// A seat the roster no longer contains resolves to `nil` rather than to an
    /// arbitrary fallback: silently substituting a different voice is worse than
    /// speaking plainly.
    func activePersona(for backend: ChatBackendID) -> PlasmaPersona? {
        guard let seatID = personaSeatID(for: backend),
              let seat = personaRoster.first(where: { $0.id == seatID }) else { return nil }
        return PlasmaPersona.persona(id: seat.personaID)
    }

    /// Built-in seats plus whatever the user has added, in roster order.
    var personaRoster: [PlasmaSeat] {
        PlasmaSeat.builtIn + customPersonaSeats
    }

    func addPersonaSeat(label: String, personaID: String) -> PlasmaSeat {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let seat = PlasmaSeat(
            id: "seat-\(UUID().uuidString.prefix(8).lowercased())",
            label: trimmed.isEmpty ? (PlasmaPersona.persona(id: personaID)?.name ?? "New seat") : trimmed,
            personaID: personaID,
            isBuiltIn: false
        )
        customPersonaSeats.append(seat)
        persistPersonaRoster()
        return seat
    }

    func removePersonaSeat(id: String) {
        guard customPersonaSeats.contains(where: { $0.id == id }) else { return }
        customPersonaSeats.removeAll { $0.id == id }
        // A seat that is deleted while agents are pointed at it must not leave
        // them resolving to nothing on the next send.
        for (backendID, seatID) in personaSeatsByBackend where seatID == id {
            personaSeatsByBackend.removeValue(forKey: backendID)
        }
        persistPersonaRoster()
        persistPersonaSeats()
    }

    // MARK: Persistence

    func loadPersonaState() {
        personaSeatsByBackend = Self.decodeSeatMap(
            UserDefaults.standard.string(forKey: Self.udPersonaSeats)
        )
        customPersonaSeats = Self.decodeRoster(
            UserDefaults.standard.string(forKey: Self.udPersonaRoster)
        )
    }

    private func persistPersonaSeats() {
        guard persistsViewState else { return }
        guard let json = Self.encode(personaSeatsByBackend) else { return }
        UserDefaults.standard.set(json, forKey: Self.udPersonaSeats)
    }

    private func persistPersonaRoster() {
        guard persistsViewState else { return }
        guard let json = Self.encode(customPersonaSeats) else { return }
        UserDefaults.standard.set(json, forKey: Self.udPersonaRoster)
    }

    nonisolated private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value), // try?-ok(unencodable persona state is dropped rather than crashing chat)
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    nonisolated static func decodeSeatMap(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:] // try?-ok(corrupt store → no personas)
    }

    nonisolated static func decodeRoster(_ json: String?) -> [PlasmaSeat] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        let decoded = (try? JSONDecoder().decode([PlasmaSeat].self, from: data)) ?? [] // try?-ok(corrupt store → built-ins only)
        // A persisted seat naming a persona this build no longer ships would
        // render as a blank orb, so it is dropped on load instead.
        return decoded.filter { seat in
            !seat.isBuiltIn && PlasmaPersona.persona(id: seat.personaID) != nil
        }
    }
}
