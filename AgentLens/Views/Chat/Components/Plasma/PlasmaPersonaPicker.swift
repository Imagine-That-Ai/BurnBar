import SwiftUI

// MARK: - Persona picker
//
// The asset's bot-seat panel: the roster of seats, and a form for adding one.
//
// Two of the asset's affordances are deliberately not ported.
//
// **Drag-to-reorder.** In the asset the seats are a launcher and their order is
// the user's own ranking. Here the roster is short, scoped to one control, and
// re-ordered far less often than it is read; a drag surface on a popover row
// would mostly get in the way of clicking it. Deletion, which is the operation
// people actually want, is on the row.
//
// **Free-form colour authoring.** The asset lets a new bot pick any hex. This
// app has a Containment Law (`DashboardChatWorkspaceToolbar.swift:20`) that
// forbids minting new identity hexes, so a new seat chooses one of the ten
// shipped personas and inherits its palette, its face and its voice. That is
// also the better product: ten distinct, designed characters beat an infinite
// space of user-mixed browns.

struct PlasmaPersonaPicker: View {
    var roster: [PlasmaSeat]
    var selectedSeatID: String?
    var onSelect: (PlasmaSeat?) -> Void
    var onCreate: (String, String) -> Void
    var onDelete: (String) -> Void

    @State private var isCreating = false
    @State private var draftLabel = ""
    @State private var draftPersonaID = PlasmaPersona.all.first?.id ?? ""

    private var isRosterFull: Bool {
        roster.filter { !$0.isBuiltIn }.count >= PlasmaSeat.customSeatLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlasmaStepHeader(step: 1, title: "Persona")
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 4) {
                    neutralRow
                    ForEach(roster) { seat in
                        seatRow(seat)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(maxHeight: 300)

            Divider().opacity(0.4).padding(.vertical, 8)

            if isCreating {
                creationForm
            } else {
                Button {
                    withAnimation(DesignSystem.Animation.gentle) { isCreating = true }
                } label: {
                    Label(isRosterFull ? "Roster is full" : "New seat", systemImage: "plus.circle")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(
                            isRosterFull ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textSecondary
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRosterFull)
                .help(isRosterFull ? "Delete a seat to make room for another." : "")
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 288)
    }

    // MARK: Rows

    private var neutralRow: some View {
        Button { onSelect(nil) } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 1) {
                    Text("No persona")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("The model's own voice")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Spacer(minLength: 4)
                PlasmaSelectionTick(isSelected: selectedSeatID == nil)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selectedSeatID == nil ? DesignSystem.Colors.surfaceElevated : .clear)
        }
        .accessibilityAddTraits(selectedSeatID == nil ? [.isButton, .isSelected] : .isButton)
    }

    /// The delete button is a *sibling* of the select button, not a child of
    /// its label. A button inside another button's label is not independently
    /// hit-tested on macOS — the click lands on the outer button — and
    /// `.accessibilityElement(children: .combine)` then folds it out of the
    /// tree entirely, leaving a hover-only tooltip as the sole affordance.
    private func seatRow(_ seat: PlasmaSeat) -> some View {
        let persona = seat.persona
        let isSelected = seat.id == selectedSeatID
        return HStack(spacing: 6) {
            Button { onSelect(seat) } label: {
                HStack(spacing: 10) {
                    PlasmaPersonaAvatar(persona: persona, diameter: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(seat.label)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        Text(persona.tagline)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    PlasmaSelectionTick(isSelected: isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(seat.label), \(persona.tagline)")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            // Survives the `.combine` above, so VoiceOver can still delete.
            .accessibilityAction(named: Text("Delete \(seat.label)")) {
                if !seat.isBuiltIn { onDelete(seat.id) }
            }

            if !seat.isBuiltIn {
                Button { onDelete(seat.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this seat")
                .accessibilityLabel("Delete \(seat.label)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? DesignSystem.Colors.surfaceElevated : .clear)
        }
        .help(persona.skills.joined(separator: " · "))
    }

    // MARK: Create

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Seat name", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .rounded))
                // Clamped as you type so the row label the seat will carry is
                // the one you can see in the field.
                .onChange(of: draftLabel) { _, new in
                    if new.count > PlasmaSeat.labelLimit {
                        draftLabel = String(new.prefix(PlasmaSeat.labelLimit))
                    }
                }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(PlasmaPersona.all) { persona in
                        Button { draftPersonaID = persona.id } label: {
                            PlasmaPersonaAvatar(
                                persona: persona,
                                diameter: 30,
                                isSelected: draftPersonaID == persona.id
                            )
                        }
                        .buttonStyle(.plain)
                        .help("\(persona.name) · \(persona.tagline)")
                        .accessibilityLabel(persona.name)
                        .accessibilityAddTraits(draftPersonaID == persona.id ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 2)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    withAnimation(DesignSystem.Animation.gentle) { isCreating = false }
                    draftLabel = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                Button("Add seat") {
                    onCreate(draftLabel, draftPersonaID)
                    draftLabel = ""
                    withAnimation(DesignSystem.Animation.gentle) { isCreating = false }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

// MARK: - Atoms

/// A persona's face on its own gradient sphere, at rest.
struct PlasmaPersonaAvatar: View {
    var persona: PlasmaPersona
    var diameter: CGFloat
    var isSelected: Bool = false

    var body: some View {
        PlasmaPersonaFace(persona: persona, width: diameter * 0.64)
            .frame(width: diameter, height: diameter)
            .background { Circle().fill(fill) }
            .overlay {
                Circle()
                    .strokeBorder(persona.color.opacity(isSelected ? 1 : 0), lineWidth: 2)
                    .padding(-2)
            }
    }

    private var fill: RadialGradient {
        RadialGradient(
            gradient: persona.gradient,
            center: UnitPoint(x: 0.35, y: 0.30),
            startRadius: 0,
            endRadius: diameter * 0.7
        )
    }
}

/// The selected-row tick. `PlasmaChoiceMark` draws a whole `PlasmaChoice`;
/// this is the bare state for rows that are not choices.
struct PlasmaSelectionTick: View {
    var isSelected: Bool

    /// Deliberately not the persona's colour. The ten persona hexes are raw
    /// asset values with no light-mode variant — `84cc16` on the botanical
    /// cream surface is about 1.9:1 — and selection is already carried by the
    /// row fill and the `.isSelected` trait, so this glyph only has to be
    /// readable.
    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
                isSelected
                    ? DesignSystem.Colors.textPrimary
                    : DesignSystem.Colors.textMuted.opacity(0.35)
            )
            .accessibilityHidden(true)
    }
}
