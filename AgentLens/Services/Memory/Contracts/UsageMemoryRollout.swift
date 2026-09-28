/// Whether usage memory's user-facing controls ship.
///
/// Off until the pipeline that honors them (session mining → extraction →
/// curation into the review inbox) is owned by the app lifecycle. Until then the
/// first-run consent sheet and the Settings toggle would promise memories that
/// never arrive, so both stay hidden while the gate lattice, spend belts and
/// cloud client below them keep shipping dark.
enum UsageMemoryRollout {
    static let surfacesUserControls = false
}
