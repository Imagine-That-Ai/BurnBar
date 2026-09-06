"""Convergence namespaces — which lineage a remote row is allowed to touch.

`_sync.py` decides what a remote revision MEANS; this module decides WHOSE
memory it is allowed to mean it about. Two lanes reach `merge_remote` through
the same inbox and the same merge — the member's own devices, and a team they
belong to (memory program D16 / P22) — and everything here exists to keep those
two from ever resolving to each other's rows.

THE INVARIANT, in one sentence (PR3 Cursor rulings T1-T3):

    Team-origin data may only ever touch team-namespaced rows in a project
    explicitly linked to that team. It can never match, overwrite, supersede or
    delete a personal row, even one sharing an engine id or a body hash.

WHY NAMESPACING A LEDGER KEY WAS NOT ENOUGH. The convergence ledger key was
namespaced by team first, and that alone left a hole: `_decide_remote_fact`
resolved a local row through `_local_memory_id` in the PERSONAL `memories.id`
space *before* the ledger was ever consulted. A sealed `memoryID` travels in
every uploaded team document, so any member of a team could read a teammate's
engine id off one, seal a new team fact naming it with a newer `updatedAt`, and
last-writer-wins over a private row the victim never shared. Namespacing has to
reach the ROW IDENTITY, not just a bookkeeping key.

SO A TEAM ROW'S LOCAL ID IS DERIVED, NEVER TAKEN FROM THE PAYLOAD.
`_team_local_memory_id` hashes `(teamID, convergence identity)`. It is:

  * unforgeable — landing on a chosen personal row would need a SHA-256
    preimage, and the payload's own `memoryID` is not an input at all;
  * deterministic across members — every member of a team derives the same local
    id for one team document, which the payload `memoryID` (each member seals
    THEIR OWN engine id) never was; and
  * inside `REMOTE_MEMORY_ID_RE`'s shape, so nothing downstream changes.

Provenance is then stamped on the row itself (written by `_write_remote_row`,
and by nothing else) so "whose namespace is this row in" is answerable in one
lookup by every other path — receipts, supersede edges, convergence — WITHOUT a
migration, which PR 3 deliberately does not take. A row written before the team
lane existed simply has no stamp, which reads as "personal": the correct answer.

AND THE STAMP LIVES WHERE A CALLER CANNOT REACH IT (T6). It went in as a
top-level `metadata["teamID"]`, and `metadata` is caller input that lands
verbatim in the row: `remember`, `update` and `import_memories` would all
persist a `teamID` a coding agent chose, which bought that agent the whole
control plane this file defends — the serving fence hid the row, the write fence
locked `forget` and `update` on it, and the unstamping was itself a locked
write. So provenance moved under the reserved `metadata["_burnbar"]["team"]`
namespace, EVERY key beginning with `_` is engine-owned, and every local write
path refuses (or, on import, strips) caller input that names one. The sync lane
is the only writer; `_metadata_team_id` is the only reader.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING, Any, NamedTuple

from ._util import _convergence_key, sha256_hex, _json_dumps, _json_loads
from .constants import (
    DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    ENGINE_METADATA_KEY,
    MEMORY_SCOPES,
    REMOTE_PREVIOUS_BODY_HASH_RE,
    REMOTE_PROJECT_ID_RE,
    REMOTE_TEAM_ID_RE,
    RESERVED_METADATA_CODE,
    RESERVED_METADATA_PREFIX,
    TEAM_ID_JSON_PATH,
    TEAM_PROJECT_LINK_MAX_BYTES,
    TEAM_PROJECT_LINK_RELATIVE_PATH,
    TEAM_PROVENANCE_SUBKEY,
)
from .store import audit_event, resolve_project

if TYPE_CHECKING:  # pragma: no cover — annotations only; importing it would be circular
    from collections.abc import Sequence

    from ._sync import _RemoteFact
    from .engine import ActiveMemory


class _SessionTeamLinks(NamedTuple):
    """What one session's checkout publishes, and which project it was read for.

    The project id travels WITH the map so the predicate can refuse a link set
    that was read for a different project rather than trusting its caller to
    have paired them correctly. A serving fence whose input can be mismatched
    silently is not a fence.
    """

    project_id: str
    teams: dict[str, str]


class _ConvergenceNamespaces:
    """The namespace half of blind sync: keys, provenance, and the team lane."""

    @staticmethod
    def _sync_identity_key(project_id: str, scope: str, body_hash: str, team_id: str | None = None) -> str:
        """The `engine_meta` key one convergence identity is remembered under.

        Personal keys are `sync_identity:<convergence key>` — BYTE-IDENTICAL to
        what every build before the team lane wrote, so no existing behaviour
        moves and no migration is needed.

        A TEAM-origin fact is namespaced `sync_identity:team:<teamID>:<key>`
        (memory program D16). That is not tidiness: a team fact and the member's
        own private row can carry the same body, and one unnamespaced ledger
        would let the team's copy silently claim the member's row — so a later
        edit of the private note would resolve to the shared one, or a
        teammate's revision would overwrite a note the member never shared.
        Namespacing keeps the two lineages apart while leaving each internally
        convergent, which is what
        `test_a_team_fact_does_not_converge_with_a_personal_row` proves.
        """
        identity = _convergence_key(project_id, scope, body_hash)
        if team_id:
            return f"sync_identity:team:{team_id}:{identity}"
        return f"sync_identity:{identity}"

    def _record_convergence_identity(
        self,
        project_id: str,
        scope: str,
        body_hash: str,
        memory_id: str,
        team_id: str | None = None,
    ) -> None:
        """Remember which local row a body belongs to, for good.

        The live `UNIQUE(project_id, scope, body_hash)` lookup only answers while
        the row still holds that body. A device that receives an edit before it
        receives the duplicate the edit replaced would otherwise key the
        duplicate to nothing and store it as a second memory, while a device that
        received them the other way round folded them into one — the same
        documents, two different beliefs. This ledger is what makes the answer
        the same on every replica whatever order the documents arrive in.

        **Every writer keeps it, not only the merge.** A member who authors a
        fact here and then edits it here has moved the body on exactly as a pair
        of merged revisions would, and a device that only ever wrote locally is
        still a replica: if the local paths left no entry, another device's
        independently-learned copy of the superseded body would land as a second
        active row on the authoring device and fold into one everywhere else.
        `_write.py::_commit_fact` and `_read.py::update` call this for the same
        reason `_merge_remote_fact` does.
        """
        self.conn.execute(
            "INSERT OR REPLACE INTO engine_meta (key, value) VALUES (?, ?)",
            (self._sync_identity_key(project_id, scope, body_hash, team_id), memory_id),
        )

    def _converged_local_id(self, fact: _RemoteFact) -> str | None:
        """The local row a remote body was last keyed to, if it still exists.

        Looked up in the arriving fact's OWN namespace: a team fact never
        resolves to a row the personal lane keyed, and vice versa.
        """
        row = self.conn.execute(
            "SELECT value FROM engine_meta WHERE key = ?",
            (self._sync_identity_key(fact.project_id, fact.scope, fact.body_hash, fact.team_id),),
        ).fetchone()
        if row is None:
            return None
        memory_id = str(row["value"])
        exists = self.conn.execute("SELECT 1 FROM memories WHERE id = ?", (memory_id,)).fetchone()
        return memory_id if exists is not None else None

    @staticmethod
    def _forget_identity_key(project_id: str, scope: str, body_hash: str, team_id: str | None = None) -> str:
        """The `forget_identity:` key one namespace remembers a hard forget under.

        Personal keys stay BYTE-IDENTICAL to every build before the team lane.
        """
        identity = _convergence_key(project_id, scope, body_hash)
        if team_id:
            return f"forget_identity:team:{team_id}:{identity}"
        return f"forget_identity:{identity}"

    @staticmethod
    def _memory_alias_key(foreign_id: str, team_id: str | None = None) -> str:
        """The `memory_alias:` key one namespace redirects a foreign id under."""
        if team_id:
            return f"memory_alias:team:{team_id}:{foreign_id}"
        return f"memory_alias:{foreign_id}"

    @staticmethod
    def _team_local_memory_id(team_id: str, project_id: str, scope: str, body_hash: str) -> str:
        """The local engine id one TEAM document lands under, derived not taken.

        See the block above. The payload's `memoryID` is deliberately NOT an
        input: it is attacker-chosen on a hostile client and it names a row in
        the member's own personal id space.
        """
        return "mem_" + sha256_hex(f"team|{team_id}|{_convergence_key(project_id, scope, body_hash)}")[:32]

    # ----- the reserved namespace: the engine's own keys on a caller's row -----
    #
    # T6. See `constants.py`. `_team_provenance_metadata` is the ONLY writer and
    # `_metadata_team_id` the ONLY reader of team provenance; the two refusal
    # helpers are what every local write path calls to keep a caller out of it.

    @staticmethod
    def _team_provenance_metadata(team_id: str, author_uid: str | None = None) -> dict[str, Any]:
        """The stamp, built in one place. `_write_remote_row` is its only caller.

        Both fields passed `_screen_remote_row`'s token shapes before they can
        reach here, so what lands is bounded tokens and never member content.
        """
        team: dict[str, Any] = {"teamID": team_id}
        if author_uid:
            team["authorUID"] = author_uid
        return {ENGINE_METADATA_KEY: {TEAM_PROVENANCE_SUBKEY: team}}

    @staticmethod
    def _metadata_team_id(metadata: Any) -> str | None:
        """Read the stamp off a row's already-parsed metadata, or None.

        Defensive at every hop: a caller CAN still write a top-level `teamID`
        (it is ordinary metadata now and means nothing), and could even write a
        `_burnbar` of the wrong shape on a store that predates the refusals, so
        anything that is not the exact nesting reads as "personal".
        """
        if not isinstance(metadata, dict):
            return None
        engine = metadata.get(ENGINE_METADATA_KEY)
        if not isinstance(engine, dict):
            return None
        team = engine.get(TEAM_PROVENANCE_SUBKEY)
        if not isinstance(team, dict):
            return None
        team_id = team.get("teamID")
        return str(team_id) if team_id and isinstance(team_id, str) else None

    @staticmethod
    def _reserved_metadata_keys(metadata: Any) -> list[str]:
        """Which engine-owned keys a caller's metadata names, if any."""
        if not isinstance(metadata, dict):
            return []
        return sorted(key for key in metadata if isinstance(key, str) and key.startswith(RESERVED_METADATA_PREFIX))

    @classmethod
    def _reserved_metadata_refusal(cls, metadata: Any) -> dict[str, Any] | None:
        """`None` when this metadata is the caller's to write; else the refusal.

        REFUSED rather than silently stripped on every path a human or an agent
        drives directly (`remember`, `memorize`, `update`): a caller that named
        `_burnbar` either misunderstands the field or is reaching for the team
        control plane, and both deserve to be told which key and why rather than
        to watch a write half-apply. The import paths strip instead — see
        `_admin.py::import_memories`.
        """
        offenders = cls._reserved_metadata_keys(metadata)
        if not offenders:
            return None
        return {
            "code": RESERVED_METADATA_CODE,
            "reason": (
                f"metadata keys beginning with '{RESERVED_METADATA_PREFIX}' are engine-owned and cannot be "
                f"set by a caller: {', '.join(offenders)}"
            ),
            "reservedKeys": offenders,
        }

    @classmethod
    def _strip_reserved_metadata(cls, metadata: dict[str, Any]) -> list[str]:
        """Drop engine-owned keys from an IMPORTED fact, and say which went.

        Import is a machine-generated payload rather than a caller assertion,
        and `import_memories` already drops three sibling engine-owned keys for
        exactly this reason: one archive row carrying a stale stamp must not
        make a whole restore unimportable. Counted in the import summary, so the
        strip is never silent.
        """
        offenders = cls._reserved_metadata_keys(metadata)
        for key in offenders:
            metadata.pop(key, None)
        return offenders

    def _row_team_id(self, memory_id: str) -> str | None:
        """Which team a local row's provenance is, or None for a personal row.

        The one authority on "may team T touch this row". A row is team-owned
        only if `_write_remote_row` stamped it, and only the team lane stamps.
        """
        if not memory_id:
            return None
        row = self.conn.execute("SELECT metadata_json FROM memories WHERE id = ?", (memory_id,)).fetchone()
        if row is None:
            return None
        return self._metadata_team_id(_json_loads(row["metadata_json"], {}) or {})

    def _row_is_addressable_by(self, memory_id: str, team_id: str | None) -> bool:
        """Whether a fact of this provenance may touch this row at all.

        Symmetric on purpose: a team fact reaches only its OWN team's rows, and
        a personal fact reaches only personal rows. The second half matters as
        much as the first — without it a member's own later revision could be
        redirected onto a row a team contributed, which is the same lineage
        confusion in the other direction.
        """
        return self._row_team_id(memory_id) == team_id

    def _refuse_cross_namespace(self, fact: _RemoteFact, holder_id: str, team_id: str | None) -> dict[str, Any]:
        """The one refusal the isolation invariant produces, from either side.

        REFUSED and acknowledged rather than parked: `UNIQUE(project_id, scope,
        body_hash)` means the convergence identity is already spoken for inside
        that project, and re-offering the document every cycle for ever changes
        nothing about that. The refusal names neither body nor holder id in its
        reason — a member must not learn from a team document which of their
        private rows it collided with, and vice versa.
        """
        audit_event(
            self.conn,
            action="memory.sync_namespace_refused",
            project_id=fact.project_id,
            subject_id=holder_id,
            labels=[f"arriving:{'team' if team_id else 'personal'}"],
            actor=self.config.actor,
        )
        return {
            "event": "REFUSE",
            "code": "NAMESPACE_MISMATCH",
            "reason": "this convergence identity belongs to a different memory namespace on this device",
            "docID": fact.doc_id,
            "memoryID": None,
        }

    def _decide_team_fact(
        self,
        fact: _RemoteFact,
        *,
        now_epoch: float | None = None,
        gap_timeout: float = DEFAULT_LINEAGE_GAP_TIMEOUT_SECONDS,
    ) -> dict[str, Any]:
        """The TEAM lane's own never-resurrect / converge / LWW, in its own space.

        The personal path above is deliberately unreachable from here (Cursor
        T2). Three differences, and each one closes a specific attack:

          1. **The local row id is DERIVED, not taken from the payload.** The
             sealed `memoryID` travels in every uploaded team document, so a
             member running a modified client could name a teammate's private
             row and last-writer-wins over it. Nothing here reads that field as
             an identity; it survives only as attribution
             (`history_meta["remoteMemoryID"]`) and as a team-namespaced alias.
          2. **The convergence-identity holder must already be this team's.** A
             personal row holding the same `(project, scope, bodyHash)` is not a
             merge target and never becomes one; the document is refused.
          3. **Forget receipts are read in the team's namespace.** A personal
             forget cannot silence a team fact, and a team's cannot silence the
             member's own memory of the same body.
        """
        team_id = str(fact.team_id)
        local_id = self._team_local_memory_id(team_id, fact.project_id, fact.scope, fact.body_hash)
        # `UNIQUE(project_id, scope, body_hash)` spans retired rows, so at most
        # one local row can ever hold this identity — and if it is not the
        # derived id, it belongs to someone else's namespace.
        holder = self.conn.execute(
            "SELECT id, valid_to FROM memories WHERE project_id = ? AND scope = ? AND body_hash = ?",
            (fact.project_id, fact.scope, fact.body_hash),
        ).fetchone()
        if holder is not None and str(holder["id"]) != local_id:
            return self._refuse_cross_namespace(fact, str(holder["id"]), team_id)
        # The sealer's own engine id, remembered inside this team's alias space
        # only, so a later team supersede edge naming it still resolves while a
        # personal revision of that same id never reaches this row.
        self._record_memory_alias(fact.memory_id, local_id, team_id)
        if holder is None:
            remembered = self._converged_local_id(fact)
            if remembered is not None and self._row_is_addressable_by(remembered, team_id):
                return self._update_remote_row(
                    fact, remembered, now_epoch=now_epoch, gap_timeout=gap_timeout, team_id=team_id
                )
            # THE DERIVED ID ONLY — never `fact.memory_id`. The id half of a
            # `_forgotten` lookup is `forget_receipt:<id>`, an UNNAMESPACED key
            # shared with the personal lane, and `fact.memory_id` is the
            # sealer's: a teammate who guessed a `mem_` id this member had
            # forgotten could otherwise have their own team fact refused as
            # `LOCALLY_FORGOTTEN` and learn from the refusal that the member had
            # forgotten that id. Refusal-direction only, but it is still the
            # personal namespace answering a team question.
            #
            # Nothing legitimate resolves through the sealed id here anyway: a
            # team row's receipts are recorded under the DERIVED id (`_purge`)
            # or under the team-namespaced identity key, never under the id the
            # sealer chose. Both of those are covered by this one call.
            forgotten = self._forgotten(local_id, fact.project_id, fact.scope, fact.body_hash, team_id)
            if forgotten is not None:
                audit_event(
                    self.conn,
                    action="memory.sync_resurrection_refused",
                    project_id=fact.project_id,
                    subject_id=local_id,
                    labels=[
                        "forgotten:by_identity" if ":team:" in forgotten else "forgotten:by_id",
                        f"team:{team_id}",
                    ],
                    actor=self.config.actor,
                )
                return {
                    "event": "REFUSE",
                    "code": "LOCALLY_FORGOTTEN",
                    "reason": "this device forgot this memory; a remote copy must not revive it",
                    "docID": fact.doc_id,
                    "memoryID": local_id,
                }
            return self._write_remote_row(fact, local_id, existing=None)
        if holder["valid_to"] is None and fact.valid_to is None and not fact.superseded_by:
            # Two members contributed the same body to the same team: one row,
            # reinforced, exactly as the personal lane folds a duplicate.
            return self._reinforce_remote(fact, local_id)
        return self._update_remote_row(fact, local_id, now_epoch=now_epoch, gap_timeout=gap_timeout, team_id=team_id)

    def _team_receipt_identity_target(self, payload: dict[str, Any], team_id: str) -> str | None:
        """The team row a team forget receipt names, from the identity it seals.

        A team document — fact or receipt — is keyed on
        `(teamProjectId, engineScope, bodyHash)`, so a receipt that carries those
        three names its target with no reference to any engine id at all. That is
        the resolution this lane prefers: it cannot be pointed at a row in
        another namespace even in principle, because the id it produces is
        `_team_local_memory_id`'s and nothing else can hold that id.

        The screening the fact lane applies to the same three fields applies
        here, for the same reasons.
        """
        project_id = str(payload.get("projectID") or "").strip()
        scope = str(payload.get("engineScope") or "").strip().lower()
        body_hash = str(payload.get("bodyHash") or "").strip().lower()
        if not REMOTE_PROJECT_ID_RE.match(project_id):
            return None
        if scope not in MEMORY_SCOPES:
            return None
        if not REMOTE_PREVIOUS_BODY_HASH_RE.match(body_hash):
            return None
        return self._team_local_memory_id(team_id, project_id, scope, body_hash)

    # ----- the SERVING fence: which sessions a team row may be read into ----
    #
    # PR3 Cursor ruling T4, and the second half of the isolation invariant at
    # the top of this file. The pull's linked-project check (T3) is necessary
    # and NOT sufficient, for two reasons that both survive it:
    #
    #   1. The engine's recall partition is PER PROJECT, and a team document
    #      carries its own `engineScope`. `scope = 'personal'` is deliberately
    #      cross-project on the personal lane — a member's own note about
    #      themselves belongs in every session — so a team fact sealed with
    #      that scope lands in project P and is then served in EVERY project on
    #      the Mac. A teammate who can seal passes T3's linked-`projectID`
    #      check and still puts their text in front of a model working in an
    #      unrelated repository. That is the reviewer's scenario, and no check
    #      performed at pull time can close it: the row is admitted correctly
    #      and read incorrectly.
    #   2. A link is a FILE, and a file can be deleted. T3 runs once, when the
    #      document arrives; the row then lives in the store for ever. Removing
    #      the team from `.openburnbar/project.json` has to stop the serving on
    #      the very next call, which only a check on the READ can do.
    #
    # So every path that serves a body puts the row to `_team_row_servable`
    # first. Personal rows are untouched by all of it: `teamID` is absent, the
    # predicate returns True, and the pre-existing project fence still decides.
    #
    # `export` is one of those paths, and it is the one that slipped: a dump is
    # a serving path like any other — whole bodies and their ids, and under
    # `all_projects` with no project fence at all — so it puts every stamped row
    # to this same predicate per row (`_admin.py::export`) and reports what it
    # held back as `teamRowsWithheld`. `reindex`, `memory_analytics` and
    # `_reinforce_recall_ids` are the named residuals: they touch team rows and
    # serve nothing, no body, no id and no lineage, to any caller.
    #
    # AMENDMENT A1 — the landing partition is not a local project id.
    #
    # T4 as first written left the pre-existing LOCAL project fence in place and
    # added this one beside it. That composition is what the two-clone proof
    # broke: a team row's landing partition is the `teamProjectId` checked into
    # the shared repository, deliberately NOT a local `proj_<32hex>` id, because
    # two members' checkouts of the same repository mint different local ids and
    # a team fact has to converge across them anyway. So `memories.project_id`
    # holds a value from a different namespace, `(m.project_id = ? OR m.scope =
    # 'personal')` can never admit it, and a project-scoped team fact was
    # filtered out of every read surface on every member's Mac — the author's
    # included — while THIS predicate said True when asked directly. Only
    # `engineScope = "personal"` team facts reached a model at all, and only
    # because a personal row is cross-project by the engine's own design.
    #
    # The rule, binding:
    #
    #   A team row is servable in this session IFF this checkout's
    #   `.openburnbar/project.json` links that team to exactly the
    #   `teamProjectId` the row landed in. The session's own local `proj_` id is
    #   not part of the comparison.
    #
    # So the local project fence stops applying to team rows — every query that
    # carries it adds `TEAM_ROW_PRESENT_SQL` (or, in Python, checks
    # `_metadata_team_id`) — and this predicate becomes the single thing that
    # decides one. Widening a SELECT grants nothing on its own: `_load_active`,
    # `recall`, `list`, `timeline` and `export` all hand what they now select
    # straight to `_team_row_servable`, which is why neutering it opens all of
    # them at once and reverting it to a landing-vs-session comparison closes all
    # of them at once. Both directions are proven
    # (`test_mutation_neutering_the_serving_predicate_serves_the_row_everywhere`,
    # `test_mutation_the_old_landing_versus_session_comparison_hides_the_row_again`).
    #
    # The write fence (T5, below) is untouched by A1 in both letter and effect:
    # `_team_write_filter` drops team rows from every session's pool regardless
    # of any project, so a wider pool is a wider set of rows it discards.

    def _session_team_links(self, project_id: str) -> _SessionTeamLinks:
        """`teamID -> teamProjectId` THIS checkout publishes, read live off disk.

        The same file the app reads (`TeamProjectLink.read`), by the same rules:
        an absent, unreadable, oversized, malformed or out-of-shape entry is no
        link at all, so every failure mode here means "this checkout publishes
        nothing to that team" and the rows stay unserved. Fail-closed in every
        direction.

        The root comes from `projects.primary_path` — the folder `resolve_project`
        recorded for this project id — so a project this engine has never seen
        resolves to no links rather than to a guessed path. A team row's own
        landing project (`teamProjectId`) is not a local checkout and has no such
        row, which is exactly right: it names nothing on this disk.

        NOT CACHED, on purpose. One bounded read of a few hundred bytes per
        serving call is the price of "unlinking stops the serving now", and
        `resolve_project` already stats this repository on the same call.
        """
        row = self.conn.execute("SELECT primary_path FROM projects WHERE project_id = ?", (project_id,)).fetchone()
        if row is None:
            return _SessionTeamLinks(project_id, {})
        path = Path(str(row["primary_path"])).joinpath(*TEAM_PROJECT_LINK_RELATIVE_PATH)
        try:
            if not path.is_file():
                return _SessionTeamLinks(project_id, {})
            with path.open("rb") as handle:
                raw = handle.read(TEAM_PROJECT_LINK_MAX_BYTES + 1)
        except OSError:
            return _SessionTeamLinks(project_id, {})
        if len(raw) > TEAM_PROJECT_LINK_MAX_BYTES:
            return _SessionTeamLinks(project_id, {})
        try:
            parsed = _json_loads(raw.decode("utf-8"), None)
        except UnicodeDecodeError:
            return _SessionTeamLinks(project_id, {})
        teams = parsed.get("teams") if isinstance(parsed, dict) else None
        if not isinstance(teams, dict):
            return _SessionTeamLinks(project_id, {})
        links: dict[str, str] = {}
        for team_id, entry in teams.items():
            # Both halves are screened to the shapes the merge already holds
            # remote strings to. A member-authored file in a shared repository
            # is remote text even when it arrives through git rather than
            # through the cloud, and one entry being wrong must not cost a
            # second team its correct one — dropped, never thrown.
            if not (isinstance(entry, dict) and isinstance(team_id, str) and REMOTE_TEAM_ID_RE.match(team_id)):
                continue
            candidate = str(entry.get("teamProjectId") or "").strip()
            if REMOTE_PROJECT_ID_RE.match(candidate):
                links[team_id] = candidate
        return _SessionTeamLinks(project_id, links)

    def _team_row_servable(
        self,
        team_id: str | None,
        landing_project_id: str,
        session_project_id: str,
        links: _SessionTeamLinks,
    ) -> bool:
        """THE serving predicate. Every read path below is a caller of this one.

        `team_id` and `landing_project_id` are the row's provenance — the team
        that authored it and the `teamProjectId` partition it landed in.
        `session_project_id` and `links` are the session's: which project the
        caller is working in and what that checkout publishes.

        A row is servable when its team publishes to EXACTLY the project the row
        landed in. Not "the session links that team somewhere": a member whose
        repository links team T to `burnbar-core` must not be handed T's rows
        that landed in `burnbar-ios`, because those are a different project's
        partition and the member linked neither their session nor their team to
        it.

        `session_project_id` is used to CHECK that `links` was read for this
        session and for nothing else. It is deliberately not compared to
        `landing_project_id`: those two are different namespaces (amendment A1
        above), a local `proj_<32hex>` never equals a `teamProjectId`, and a
        build that compared them served no project-scoped team fact to anybody.
        """
        if not team_id:
            return True
        if links.project_id != session_project_id:
            # A link set read for another project decides nothing here.
            return False
        return links.teams.get(team_id) == landing_project_id

    def _team_serve_filter(self, memories: Sequence[ActiveMemory], project_id: str) -> list[ActiveMemory]:
        """The predicate over a loaded pool — `recall` (and so `recall_pack`,
        `ask` and the session briefing), `entities` and `relations`.

        A new list: `_load_active` hands back a CACHED one that other projects'
        calls share, and filtering it in place would make one session's fence
        another session's missing memories.
        """
        links = self._session_team_links(project_id)
        return [
            memory
            for memory in memories
            if self._team_row_servable(self._metadata_team_id(memory.metadata), memory.project_id, project_id, links)
        ]

    def _team_serves_memory(self, memory_id: str, project_id: str | None = None) -> bool:
        """The predicate for the id-addressed surfaces — `get`, `history`, `timeline`.

        A row that does not exist is not a team row, and answering "servable"
        keeps the caller's own not-found handling in charge of saying so.

        `project_id` is resolved from the working directory only when it is
        actually needed, i.e. only for a team row: `get` and `history` carry no
        project argument today, and resolving one on every personal read would
        put a `projects` upsert on paths that never had one.
        """
        row = self.conn.execute("SELECT project_id, metadata_json FROM memories WHERE id = ?", (memory_id,)).fetchone()
        if row is None:
            return True
        team_id = self._metadata_team_id(_json_loads(row["metadata_json"], {}) or {})
        if team_id is None:
            return True
        if project_id is None:
            project_id = resolve_project(self.conn, None)[0]
        return self._team_row_servable(
            team_id, str(row["project_id"]), project_id, self._session_team_links(project_id)
        )

    def _team_visibility_sql(self, project_id: str) -> tuple[str, list[str]]:
        """The predicate as a WHERE clause, for `list`.

        `list` counts and paginates in SQL, so its fence has to be SQL or its
        `total` and its page boundaries would describe rows the caller never
        receives. It is still THIS predicate that decides: every
        `(teamID, landing project)` pair the store actually holds is put to
        `_team_row_servable`, and only the pairs it admits are bound into the
        clause. There is no second copy of the rule to drift — neutering the
        predicate opens this path exactly as it opens the others, which is what
        `test_the_serving_fence_is_the_only_thing_holding_a_team_row_back`
        depends on.
        """
        links = self._session_team_links(project_id)
        # S608: the interpolated value is `TEAM_ID_JSON_PATH`, a module constant.
        pairs = self.conn.execute(
            f"SELECT DISTINCT json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') AS team_id, project_id "  # noqa: S608
            f"FROM memories WHERE json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') IS NOT NULL"
        ).fetchall()
        admitted = [
            (str(row["team_id"]), str(row["project_id"]))
            for row in pairs
            if self._team_row_servable(str(row["team_id"]), str(row["project_id"]), project_id, links)
        ]
        clause = f"json_extract(m.metadata_json, '{TEAM_ID_JSON_PATH}') IS NULL"
        if not admitted:
            return clause, []
        allowed = " OR ".join(
            [f"(json_extract(m.metadata_json, '{TEAM_ID_JSON_PATH}') = ? AND m.project_id = ?)"] * len(admitted)
        )
        return f"({clause} OR {allowed})", [value for pair in admitted for value in pair]

    # ----- the WRITE fence: which rows a local write may see and change -----
    #
    # PR3 Cursor ruling T5, and the third and last face of the isolation
    # invariant. T4 fenced every path that SERVES a body; `remember` serves
    # nothing and so passed straight through it, while still loading its
    # near-duplicate / judge / conflict pool with
    # `_load_active(..., include_personal_cross_project=True)`. A team row
    # sealed `engineScope = "personal"` was therefore a live candidate in a
    # project linked to no team at all, and a near-duplicate reinforce handed
    # the team body and the team row id back to that session — the exact leak
    # T4 closed on recall, through a surface that never calls recall. Worse, the
    # judge could answer UPDATE or DELETE naming the row, and a negation cue
    # could retire it, so unrelated work could edit or destroy a team's memory.
    #
    # The rule is stronger than "filter the pool in unlinked sessions", because
    # linking a project grants READ and never authorship:
    #
    #   A team-origin row is never mutated or retired by a write the local user
    #   initiated, in ANY session. It changes through the team lane — a pull, or
    #   a receipt — or through an explicitly team-scoped operation, and through
    #   nothing else.
    #
    # That single rule subsumes the visibility half: a row no local write may
    # change has no business being in a local write's candidate set anywhere, so
    # `_team_write_filter` drops team rows from every session's pool rather than
    # only from unlinked ones. `_team_row_servable` stays load-bearing on this
    # side too, in the one place it still decides something: HOW MUCH A REFUSAL
    # MAY SAY. An unlinked session may not learn the row exists, so it gets the
    # same `TEAM_PROJECT_NOT_LINKED` the read surfaces return; a linked session
    # may see it, so its refusal names the row and the real reason.

    @staticmethod
    def _team_row_writable_by_local_user(team_id: str | None, *, team_scoped: bool = False) -> bool:
        """THE write predicate. Every local-user write path below is a caller.

        `team_id` is the row's provenance. `team_scoped` is the caller saying
        "this operation IS the team lane" — the merge's own retirements pass it,
        because a remote revision retiring the row it supersedes is the team lane
        working, not a local user reaching into it. It defaults to False so a new
        write path is fenced by omission rather than opened by it.

        A personal row has no `teamID` and is not this predicate's business:
        True, and whatever decided it before still decides it.
        """
        if not team_id:
            return True
        return team_scoped

    def _team_write_filter(
        self, memories: Sequence[ActiveMemory], project_id: str, *, team_scoped: bool = False
    ) -> list[ActiveMemory]:
        """The predicate over a write's candidate pool — `_commit_fact`, and so
        `remember`, `memorize`, `import_memories` and every extractor batch.

        A new list, for the same reason `_team_serve_filter` builds one:
        `_load_active` returns a CACHED list shared with other projects' calls.

        `project_id` is unused by the decision and kept in the signature on
        purpose — it is what a reader expects to pass a project fence, and its
        absence would read as an oversight rather than as the deliberate "this
        rule does not vary by session" it is.
        """
        del project_id  # the rule is session-independent; see the block above
        return [
            memory
            for memory in memories
            if self._team_row_writable_by_local_user(self._metadata_team_id(memory.metadata), team_scoped=team_scoped)
        ]

    def _team_write_refusal(
        self,
        memory_id: str,
        *,
        row: Any = None,
        project_id: str | None = None,
        project_path: str | None = None,
        team_scoped: bool = False,
    ) -> dict[str, str] | None:
        """`None` when a local write may touch this id; otherwise the refusal.

        The refusal body is built here, once, so the id-addressed write surfaces
        (`update`, `review`, `forget`, `forget_all`'s selection, `fold`) cannot
        drift into disagreeing about what a refused write says. Callers add
        their own `status` key, which differs by surface.

        `row` lets a caller that already read the row hand it over rather than
        pay a second lookup; it needs `project_id` and `metadata_json`. The
        session's project is resolved only for a team row — from `project_id`
        when the caller already has one, else from `project_path`, else from the
        working directory, as `get` and `history` do — so a personal write never
        gains a `projects` upsert it did not have before.
        """
        if row is None:
            row = self.conn.execute(
                "SELECT project_id, metadata_json FROM memories WHERE id = ?", (memory_id,)
            ).fetchone()
        if row is None:
            # A row that does not exist is not a team row: let the caller's own
            # not-found handling answer, exactly as `_team_serves_memory` does.
            return None
        team_id = self._metadata_team_id(_json_loads(row["metadata_json"], {}) or {})
        if self._team_row_writable_by_local_user(team_id, team_scoped=team_scoped):
            return None
        if project_id is None:
            project_id = resolve_project(self.conn, project_path)[0]
        if not self._team_row_servable(
            team_id, str(row["project_id"]), project_id, self._session_team_links(project_id)
        ):
            return {"code": "TEAM_PROJECT_NOT_LINKED", "memoryID": memory_id}
        return {
            "code": "TEAM_ROW_NOT_WRITABLE",
            "memoryID": memory_id,
            "reason": "this memory belongs to a team; it changes through the team lane, not through a local write",
        }

    # ----- T6 recovery: provenance no team lane can account for -----
    #
    # The refusals above close the door; this reopens the rows that got through
    # before it was closed. A row is team-owned only because `_write_remote_row`
    # stamped it, and that method never lands a row without
    # `_merge_remote_fact` recording its convergence identity under
    # `sync_identity:team:<teamID>:<key>` pointing back at the row. So a stamped
    # row that NO team ledger entry names is a row the team lane never wrote —
    # the shape a caller-forged stamp leaves — and it is currently invisible to
    # every read and locked against `forget` and `update`, with the unstamping
    # itself locked. `doctor` reports it; `doctor(apply=True)` (gated
    # `memory_write` at the tool boundary) un-stamps it, and the row is a
    # personal row again: visible, updatable, forgettable.

    def orphan_team_provenance(self, *, limit: int = 500) -> list[dict[str, str]]:
        """Stamped rows no `sync_identity:team:…` entry accounts for. Read-only."""
        # S608: the interpolated value is `TEAM_ID_JSON_PATH`, a module constant.
        rows = self.conn.execute(
            f"SELECT id, project_id, json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') AS team_id "  # noqa: S608
            f"FROM memories WHERE json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') IS NOT NULL "
            "ORDER BY id LIMIT ?",
            (limit,),
        ).fetchall()
        orphans: list[dict[str, str]] = []
        for row in rows:
            memory_id, team_id = str(row["id"]), str(row["team_id"])
            # `substr`, not `LIKE`: a team token contains `_`, which LIKE reads
            # as a single-character wildcard, and a fence must not depend on an
            # over-matching prefix.
            prefix = f"sync_identity:team:{team_id}:"
            attested = self.conn.execute(
                "SELECT 1 FROM engine_meta WHERE value = ? AND substr(key, 1, ?) = ? LIMIT 1",
                (memory_id, len(prefix), prefix),
            ).fetchone()
            if attested is None:
                orphans.append({"memoryID": memory_id, "projectID": str(row["project_id"]), "teamID": team_id})
        return orphans

    def _clear_team_provenance(self, memory_id: str) -> bool:
        """Un-stamp one row. The repair half of `orphan_team_provenance`.

        Only the reserved namespace is touched: the caller's own metadata keys
        — a top-level `teamID` among them, which means nothing to this engine —
        are left exactly as they were, because repairing a fence is no licence
        to edit a member's data.
        """
        row = self.conn.execute("SELECT metadata_json FROM memories WHERE id = ?", (memory_id,)).fetchone()
        if row is None:
            return False
        metadata = _json_loads(row["metadata_json"], {}) or {}
        engine = metadata.get(ENGINE_METADATA_KEY)
        if not isinstance(engine, dict) or TEAM_PROVENANCE_SUBKEY not in engine:
            return False
        engine.pop(TEAM_PROVENANCE_SUBKEY, None)
        if not engine:
            metadata.pop(ENGINE_METADATA_KEY, None)
        self.conn.execute(
            "UPDATE memories SET metadata_json = ? WHERE id = ?",
            (_json_dumps(metadata), memory_id),
        )
        return True
