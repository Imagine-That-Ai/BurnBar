#!/usr/bin/env python3
"""Two clones, one team, one fact — the D16 ship blocker, proved end to end.

WHAT THIS FILE EXISTS FOR. `project_identity_fingerprint` keys a repository on
`origin:<remote.origin.url>` plus its root commit
(`project_code_memory.py::project_identity_fingerprint`), so a member who cloned
over SSH and a member who cloned over HTTPS derive DIFFERENT `proj_` ids for the
same repository — and an adoption outranks the fingerprint entirely
(`resolve_project_id`). Every team document id would inherit that split, and the
failure would be silent and asymmetric: uploads keep succeeding, dedup never
fires, and each half of the team sees a team space that looks half empty.

The mitigation is that a team document id derives from the CHECKED-IN
`teams.<teamId>.teamProjectId` in `.openburnbar/project.json` — the same bytes on
every clone by construction — and never from the git fingerprint
(`AgentLens/Services/CloudSync/TeamMemoryUploadEligibility.swift::TeamProjectLink`,
design §3(a)). Until this file it was asserted by unit tests and by
construction, never once end to end, which is why `docs/security/
BurnBar-threat-model.md` carried an audit note saying so.

WHAT IS REAL HERE AND WHAT IS MODELLED.

  * REAL: two actual `git init` repositories on disk with the same root commit
    and different `remote.origin.url` forms; two independent `MemoryEngine`
    instances over two separate SQLite stores; the real `remember` / `review` /
    `merge_remote` / `recall` / `list` surfaces; the real screening, the real
    convergence ledger, the real serving and write fences.
  * MODELLED: the cloud. `_FakeTeamCloud` is `team_memory_facts/{teamId}/facts`
    as a dict, with the app's conditional-LWW upload rule
    (`KnowledgeSyncService.swift:682-690`) and the pull's link check (PR3 Cursor
    ruling T3). The seal/open step is a no-op because the engine never holds the
    key: the daemon hands `merge_remote` plaintext it has already verified. No
    Firestore emulator is required, and none is used.
  * FAITHFUL: the document id is derived exactly as the app derives it —
    `pensieveSlugHmac("team-memory-fact:<teamId>:<convergenceKey>", teamSlugKey)`
    over the engine's own `_convergence_key`, reimplemented here from the Rust
    (`crates/openburnbar-domain-core/domain-core/src/cloudvault.rs:263`) so this
    file agrees with the shipped derivation rather than with itself.

WHAT THIS FILE DOES NOT PROVE. It does not exercise CloudVault sealing, the AAD,
the key ring, `firestore.rules`, the roster callables or the Swift pull service:
those have their own suites (`AgentLensTests/Active/TeamMemorySyncTests.swift`,
`functions/scripts/test-firestore-rules.mjs`). What it proves is the one claim
the threat model could not make — that two differently-cloned checkouts of one
repository converge on one team document — plus the negative that says the
mitigation is load-bearing.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import subprocess
import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import memory_engine as me  # noqa: E402
from memory_engine._util import _convergence_key, canonical_body_hash  # noqa: E402
import project_code_memory as pcm  # noqa: E402

TEAM_ID = "team_0123456789abcdef"
# The checked-in id both clones publish. Inside `REMOTE_PROJECT_ID_RE` and
# deliberately NOT `proj_`-shaped: it is a name a team agreed on and committed,
# not an id any engine minted.
TEAM_PROJECT_ID = "burnbar-core"
OTHER_TEAM_PROJECT_ID = "burnbar-core-fork"

UID_A = "uid_alice"
UID_B = "uid_bob"

T1 = "2026-08-01T09:00:00Z"
T2 = "2026-08-01T10:00:00Z"
T3 = "2026-08-01T11:00:00Z"

# The team's non-rotating slug key. 32 bytes, built at runtime from a label so no
# key-shaped literal ever enters the repository — it seals nothing (design
# §3(a): "it names documents, it does not protect them") and every member holds
# it, but a 64-hex literal beside the word "key" is a secret-scanner finding and
# a bad habit besides.
TEAM_SLUG_KEY = hashlib.sha256(b"openburnbar-test-team-slug-key").digest()

SSH_ORIGIN = "git@github.com:acme/widgets.git"
HTTPS_ORIGIN = "https://github.com/acme/widgets.git"

FACT_BODY = "The merge queue is the only path to main."
SECOND_BODY = "Nightly builds are not a merge gate."


# ---------------------------------------------------------------------------
# The app's document-id derivation, reimplemented from the Rust
# ---------------------------------------------------------------------------


def _hkdf_sha256(key: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 HKDF-SHA256. `derive_key_32` in `cloudvault.rs`."""
    prk = hmac.new(salt, key, hashlib.sha256).digest()
    okm = b""
    block = b""
    counter = 1
    while len(okm) < length:
        block = hmac.new(prk, block + info + bytes([counter]), hashlib.sha256).digest()
        okm += block
        counter += 1
    return okm[:length]


def _pensieve_slug_hmac(slug: str, key: bytes) -> str:
    """`CloudVaultCrypto.pensieveSlugHmac`: HKDF then HMAC, full 64-hex digest.

    Parity: `HKDF<SHA256>(key, salt: ∅, info: "pensieve-dedup:slug")` →
    `HMAC<SHA256>(slug)` (`CloudVaultCrypto.swift:800-809`,
    `cloudvault.rs:263-266`). An empty HKDF salt and a zero-filled one are the
    same HMAC key, which is why `b""` here matches the Rust's `b""`.
    """
    derived = _hkdf_sha256(key, b"", b"pensieve-dedup:slug")
    return hmac.new(derived, slug.encode("utf-8"), hashlib.sha256).hexdigest()


def _team_doc_id(team_id: str, team_project_id: str, engine_scope: str, body_hash: str) -> str:
    """`TeamMemorySyncService.deriveDocID`, in Python.

    The pre-image's project half is the argument, and every caller in this file
    passes `_team_project_id_for`'s answer — which is what the mutation test at
    the bottom swaps out.
    """
    key = _convergence_key(team_project_id, engine_scope, body_hash)
    return _pensieve_slug_hmac(f"team-memory-fact:{team_id}:{key}", TEAM_SLUG_KEY)


# ---------------------------------------------------------------------------
# Two real clones of one repository
# ---------------------------------------------------------------------------

# Every input to a commit hash, pinned: the tree, the message, the author and
# the committer with their instants. Two `git init`s under these produce the
# SAME root commit, which is what makes the two directories two clones of one
# repository rather than two unrelated repositories that happen to share a
# remote name.
_FIXED_ENV = {
    "GIT_AUTHOR_NAME": "Root",
    "GIT_AUTHOR_EMAIL": "root@burnbar.dev",
    "GIT_AUTHOR_DATE": "2020-01-01T00:00:00+0000",
    "GIT_COMMITTER_NAME": "Root",
    "GIT_COMMITTER_EMAIL": "root@burnbar.dev",
    "GIT_COMMITTER_DATE": "2020-01-01T00:00:00+0000",
}


def _git(path: Path, *args: str) -> str:
    import os

    env = dict(os.environ)
    env.update(_FIXED_ENV)
    result = subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True, text=True, env=env)
    return result.stdout.strip()


def _clone(path: Path, origin: str) -> Path:
    """One member's checkout: same root commit as its sibling, its own remote form."""
    path.mkdir(parents=True, exist_ok=True)
    _git(path, "init", "-q")
    (path / "app.py").write_text("# widgets\n", encoding="utf-8")
    _git(path, "add", "app.py")
    _git(path, "commit", "-qm", "init")
    _git(path, "remote", "add", "origin", origin)
    return path


def _root_commit(path: Path) -> str:
    return _git(path, "rev-list", "--max-parents=0", "HEAD")


def _write_link(root: Path, links: dict[str, str] | None, *, commit: bool = True) -> None:
    """The checked-in `.openburnbar/project.json`. `None` deletes it.

    CHECKED IN is the operative word, and now the default: the engine reads the
    COMMITTED file (D16 Cursor ruling), so a written-and-uncommitted entry is not
    a link and nothing in this proof would converge on one. `commit=False` is for
    the tests that are about exactly that distinction.
    """
    path = root / ".openburnbar" / "project.json"
    if links is None:
        path.unlink(missing_ok=True)
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"teams": {team: {"teamProjectId": project} for team, project in links.items()}}),
            encoding="utf-8",
        )
    if commit:
        _commit_link(root)


def _commit_link(root: Path) -> None:
    """Commit whatever the link file currently is — its content, or its absence."""
    _git(root, "add", "-A", "--", ".")
    if _git(root, "status", "--porcelain"):
        _git(root, "commit", "-qm", "link")


def _team_project_id_for(member: _Member, team_id: str) -> str | None:
    """The doc-id pre-image's project half: the CHECKED-IN id, never the git one.

    THE WHOLE MITIGATION, in one function, so that the mutation test at the
    bottom of this file can replace exactly it — see
    `_git_fingerprint_project_id` — and watch the proof collapse.

    It asks the ENGINE'S OWN reader rather than re-parsing the file, so this
    proof rides on the shipped eligibility rule — working tree AND `HEAD`, per
    entry — instead of on a second implementation that could agree with the
    design while the product disagreed with both.
    """
    return member.engine._session_team_links(member.engine_project_id).teams.get(team_id)


def _git_fingerprint_project_id(member: _Member, team_id: str) -> str | None:
    """The mutation: derive from THIS Mac's git identity instead of the commit.

    This is what the design refused, written out, so the test that installs it
    is showing the real alternative rather than a strawman.
    """
    return member.engine_project_id


# ---------------------------------------------------------------------------
# The fake cloud, and the two members that talk through it
# ---------------------------------------------------------------------------


class _FakeTeamCloud:
    """`team_memory_facts/{teamId}/facts/{docID}` as a dict.

    Two rules from the shipped lane and nothing else: a document is addressed by
    its derived id, and an upload is CONDITIONAL — a revision no newer than the
    one already there is skipped rather than written
    (`KnowledgeSyncService.swift:682-690`). No key, no AAD, no envelope: the
    engine holds no key on either side of this boundary, so modelling the crypto
    here would model nothing the engine can observe.
    """

    def __init__(self) -> None:
        self.docs: dict[str, dict[str, object]] = {}
        self.skipped_uploads = 0

    def upload(self, doc_id: str, payload: dict[str, object]) -> bool:
        existing = self.docs.get(doc_id)
        updated_at = str(payload["updatedAt"])
        if existing is not None and str(existing["updatedAt"]) >= updated_at:
            self.skipped_uploads += 1
            return False
        self.docs[doc_id] = {
            "docID": doc_id,
            "updatedAt": updated_at,
            "uid": payload["authorUID"],
            "payload": payload,
        }
        return True


class _Member:
    """One member: one Mac, one store, one checkout, one uid."""

    def __init__(self, engine: me.MemoryEngine, root: Path, uid: str) -> None:
        self.engine = engine
        self.root = root
        self.uid = uid
        self.engine_project_id = me.resolve_project(engine.conn, str(root))[0]
        self.pull_cursor = ""

    def close(self) -> None:
        self.engine.close()


def _member(tmp_path: Path, name: str, origin: str, uid: str) -> _Member:
    root = _clone(tmp_path / name, origin)
    engine = me.MemoryEngine.open(tmp_path / f"{name}.sqlite", provider=me.FakeEmbeddingProvider())
    return _Member(engine, root, uid)


def _remember_and_approve(member: _Member, body: str, *, scope: str = "personal") -> str:
    """A member learns a fact and approves it — the app's upload precondition.

    `TeamMemoryUploadRefusal.notApproved`: a quarantined or rejected row never
    leaves the device on any lane, so nothing here is sealable until this runs.

    The default scope is `personal` only because that is what the convergence
    properties below are stated over; it is no longer load-bearing. It once was:
    before amendment A1 a `project`-scoped team row landed in the
    `teamProjectId` partition and then failed the engine's per-project recall
    fence, so only a personal one reached a model.
    `test_a_project_scoped_team_fact_lands_and_reaches_the_checkout_that_links_it`
    now pins the corrected behaviour for both scopes.
    """
    result = member.engine.remember(body, project_path=str(member.root), kind="fact", scope=scope)
    memory_id = str(result["memoryID"])
    reviewed = member.engine.review(memory_id, "approved")
    assert reviewed["status"] == "ok", reviewed
    return memory_id


def _seal(member: _Member, memory_id: str, *, team_id: str, updated_at: str) -> tuple[str, dict[str, object]]:
    """What the app seals for one local row: the outer doc id and the payload.

    The body hash is RECOMPUTED from the body this device holds, never read off
    a field — `TeamMemorySyncService.canonicalBodyHash`'s reasoning, which is
    `_screen_remote_row`'s: the sender's `bodyHash` is advice about the sender's
    own store. `memoryID` is the SEALER's own engine id, which is exactly why
    the receiving engine derives its own (Cursor ruling T2) instead of trusting
    it.
    """
    row = member.engine._get_row(memory_id)
    assert row is not None, memory_id
    memory = member.engine._row_to_memory(row)
    assert memory is not None
    public = memory.public(include_body=True)
    body = str(public["body"])
    scope = str(public["scope"])
    team_project_id = _team_project_id_for(member, team_id)
    assert team_project_id is not None, "this checkout publishes nothing to that team"
    doc_id = _team_doc_id(team_id, team_project_id, scope, canonical_body_hash(body))
    payload: dict[str, object] = {
        "schemaVersion": 2,
        "memoryID": memory_id,
        "text": body,
        "kind": str(public["kind"]),
        "scope": {"userID": member.uid, "appID": "openburnbar"},
        "confidence": float(public["confidence"]),
        "citations": [],
        "validFrom": updated_at,
        "updatedAt": updated_at,
        "validTo": None,
        "supersededBy": None,
        "tags": list(public["tags"]),
        "bodyHash": None,
        # THE LANDING PARTITION: the checked-in id, not `member.engine_project_id`.
        "projectID": team_project_id,
        "engineScope": scope,
        "teamID": team_id,
        "authorUID": member.uid,
    }
    return doc_id, payload


def _push(member: _Member, cloud: _FakeTeamCloud, memory_id: str, *, team_id: str, updated_at: str) -> str:
    doc_id, payload = _seal(member, memory_id, team_id=team_id, updated_at=updated_at)
    cloud.upload(doc_id, payload)
    return doc_id


def _pull(member: _Member, cloud: _FakeTeamCloud, *, team_id: str) -> dict[str, object]:
    """The member's pull: the T3 link check, then the real `merge_remote`.

    The link check is the Swift pull's (`TeamMemoryPullService`
    `.projectNotLinkedToTeam`): a sealed `teamProjectId` is admitted only by
    appearing in THIS checkout's link file for THIS team. It is modelled here
    because it decides which documents ever reach the engine, and the whole
    negative case below turns on it.
    """
    linked = _team_project_id_for(member, team_id)
    entries: list[dict[str, object]] = []
    refused_not_linked: list[str] = []
    for doc in sorted(cloud.docs.values(), key=lambda item: (str(item["updatedAt"]), str(item["docID"]))):
        updated_at = str(doc["updatedAt"])
        if updated_at <= member.pull_cursor:
            continue
        payload = dict(doc["payload"])  # type: ignore[arg-type]
        if payload.get("projectID") != linked:
            # PERMANENT, and the cursor still moves — the refusal is lossless by
            # rewind-on-link, not by freezing.
            refused_not_linked.append(str(doc["docID"]))
            member.pull_cursor = max(member.pull_cursor, updated_at)
            continue
        entries.append(
            {
                "docID": str(doc["docID"]),
                "userID": member.uid,
                "engineMemoryID": str(payload["memoryID"]),
                "payloadJSON": json.dumps(payload),
                "remoteUpdatedAt": updated_at,
            }
        )
        member.pull_cursor = max(member.pull_cursor, updated_at)
    merged = member.engine.merge_remote(entries) if entries else {"applied": 0, "reinforced": 0, "refused": 0}
    return {**merged, "refusedNotLinked": refused_not_linked}


def _team_row_ids(member: _Member) -> set[str]:
    """Every row in this member's store carrying team provenance."""
    from memory_engine.constants import TEAM_ID_JSON_PATH

    rows = member.engine.conn.execute(
        f"SELECT id FROM memories WHERE json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') IS NOT NULL"  # noqa: S608
    ).fetchall()
    return {str(row["id"]) for row in rows}


def _row_state(member: _Member, memory_id: str) -> tuple[object, ...]:
    row = member.engine.conn.execute(
        "SELECT id, project_id, scope, body_hash, review_status, valid_to, superseded_by, updated_at, metadata_json "
        "FROM memories WHERE id = ?",
        (memory_id,),
    ).fetchone()
    assert row is not None, memory_id
    return tuple(row)


def _recalled_ids(member: _Member, query: str) -> set[str]:
    return {str(item["memoryID"]) for item in member.engine.recall(query, project_path=str(member.root))["results"]}


@pytest.fixture
def team(tmp_path: Path):
    """Two members, two clones, one checked-in link, one fake cloud."""
    alice = _member(tmp_path, "alice", SSH_ORIGIN, UID_A)
    bob = _member(tmp_path, "bob", HTTPS_ORIGIN, UID_B)
    _write_link(alice.root, {TEAM_ID: TEAM_PROJECT_ID})
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID})
    try:
        yield alice, bob, _FakeTeamCloud()
    finally:
        alice.close()
        bob.close()


# ---------------------------------------------------------------------------
# 1. The risk is real
# ---------------------------------------------------------------------------


def test_an_ssh_clone_and_an_https_clone_derive_different_git_project_ids(team) -> None:
    """The premise. If this ever stops holding, the mitigation is moot — say so LOUDLY.

    `project_identity_fingerprint` hashes `origin:<remote.origin.url>` verbatim
    beside the root commit, and the two URL forms of one GitHub repository are
    different strings. Same repository, same root commit, two ids. This is not a
    bug being fixed here; it is the condition the doc-id derivation is designed
    around, and a test suite that assumed it without checking would keep passing
    if it went away.
    """
    alice, bob, _ = team

    # Same repository: byte-identical root commit.
    assert _root_commit(alice.root) == _root_commit(bob.root)

    fp_a = pcm.project_identity_fingerprint(alice.root)
    fp_b = pcm.project_identity_fingerprint(bob.root)
    assert fp_a.startswith("git:origin:") and fp_b.startswith("git:origin:")
    assert SSH_ORIGIN in fp_a
    assert HTTPS_ORIGIN in fp_b
    assert fp_a != fp_b, (
        "THE PREMISE HAS CHANGED: an SSH clone and an HTTPS clone of one repository now "
        "fingerprint identically, so the cross-member split this file exists to mitigate is "
        f"void. Re-read docs/superpowers/plans/2026-09-05-team-memory-design.md §6. ({fp_a})"
    )

    id_a = pcm.project_id_for_fingerprint(fp_a, "fallback")
    id_b = pcm.project_id_for_fingerprint(fp_b, "fallback")
    assert id_a.startswith("proj_") and id_b.startswith("proj_")
    assert id_a != id_b

    # And the engines agree: each member's own project id is the split one.
    assert alice.engine_project_id != bob.engine_project_id
    assert {alice.engine_project_id, bob.engine_project_id} == {id_a, id_b}


def test_the_checked_in_link_is_the_only_thing_the_two_clones_share(team) -> None:
    """The mitigation's input, isolated: same file, same bytes, both checkouts."""
    alice, bob, _ = team
    assert _team_project_id_for(alice, TEAM_ID) == TEAM_PROJECT_ID
    assert _team_project_id_for(bob, TEAM_ID) == TEAM_PROJECT_ID
    assert _team_project_id_for(alice, TEAM_ID) != alice.engine_project_id
    assert _team_project_id_for(bob, TEAM_ID) != bob.engine_project_id


# ---------------------------------------------------------------------------
# 2. The mitigation holds end to end
# ---------------------------------------------------------------------------


def test_both_clones_derive_the_same_team_document_id_and_convergence_key(team) -> None:
    """The ship blocker, in its narrowest form: one fact, one id, two clones.

    Both members learn the same fact independently — no cloud involved yet — and
    seal it. The document ids and the convergence keys match, because the
    pre-image's project half came out of the repository rather than out of git.
    """
    alice, bob, _ = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    b_mid = _remember_and_approve(bob, FACT_BODY)
    assert a_mid != b_mid, "each member minted their own local engine id, as they must"

    a_doc, a_payload = _seal(alice, a_mid, team_id=TEAM_ID, updated_at=T1)
    b_doc, b_payload = _seal(bob, b_mid, team_id=TEAM_ID, updated_at=T2)

    assert a_doc == b_doc
    assert len(a_doc) == 64 and int(a_doc, 16) >= 0
    assert a_payload["projectID"] == b_payload["projectID"] == TEAM_PROJECT_ID

    body_hash = canonical_body_hash(FACT_BODY)
    shared_key = _convergence_key(TEAM_PROJECT_ID, "personal", body_hash)
    assert a_doc == _pensieve_slug_hmac(f"team-memory-fact:{TEAM_ID}:{shared_key}", TEAM_SLUG_KEY)

    # And the id each engine will land the document under is the same on both
    # sides too — derived from the same three, by the same function.
    assert me.MemoryEngine._team_local_memory_id(
        TEAM_ID, TEAM_PROJECT_ID, "personal", body_hash
    ) == me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", body_hash)

    # The git ids, meanwhile, would have given two documents.
    assert _team_doc_id(TEAM_ID, alice.engine_project_id, "personal", body_hash) != _team_doc_id(
        TEAM_ID, bob.engine_project_id, "personal", body_hash
    )


def test_a_fact_alice_seals_lands_in_bobs_team_namespace(team) -> None:
    """A remembers, approves, uploads; B pulls; the fact is there and it is B's team's.

    The landing id is DERIVED (`_team_local_memory_id`), never the sealed
    `memoryID` — so B's row is not named by anything Alice chose, and yet both
    members name it identically.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    doc_id = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    assert len(cloud.docs) == 1

    merged = _pull(bob, cloud, team_id=TEAM_ID)
    assert merged["applied"] == 1, merged
    assert merged["refusedNotLinked"] == []

    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY))
    assert _team_row_ids(bob) == {landed}
    assert landed != a_mid, "the sealed memoryID is not an identity on this lane (Cursor T2)"

    row = bob.engine.conn.execute("SELECT project_id, scope FROM memories WHERE id = ?", (landed,)).fetchone()
    assert str(row["project_id"]) == TEAM_PROJECT_ID
    assert str(row["scope"]) == "personal"

    # Served into Bob's checkout, because that checkout links this team to this
    # landing project — the T4 fence, exercised through the real recall.
    assert landed in _recalled_ids(bob, "merge queue main")

    # Alice pulls her own team's copy back and lands the SAME id: one fact, one
    # row id, two Macs, two different git project identities.
    alice_merged = _pull(alice, cloud, team_id=TEAM_ID)
    assert alice_merged["applied"] == 1, alice_merged
    assert _team_row_ids(alice) == {landed}
    assert cloud.docs[doc_id]["payload"]["projectID"] == TEAM_PROJECT_ID  # type: ignore[index]


def test_a_second_identical_fact_from_bob_converges_instead_of_duplicating(team) -> None:
    """Two members learn one thing. One document, one row, on both Macs.

    This is the property the split would have broken silently: with two
    different `teamProjectId`s the two uploads address two documents, both
    succeed, and neither member ever sees an error.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    a_doc = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    _pull(bob, cloud, team_id=TEAM_ID)
    _pull(alice, cloud, team_id=TEAM_ID)

    # Bob independently writes the same fact in his own checkout and contributes it.
    b_mid = _remember_and_approve(bob, FACT_BODY)
    b_doc = _push(bob, cloud, b_mid, team_id=TEAM_ID, updated_at=T3)
    assert b_doc == a_doc
    assert len(cloud.docs) == 1, "a converging contribution is a REVISION, not a second document"

    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY))
    back = _pull(alice, cloud, team_id=TEAM_ID)
    assert back["applied"] + back["reinforced"] == 1, back
    assert _team_row_ids(alice) == {landed}
    assert _team_row_ids(bob) == {landed}

    # One team row per member, and exactly one convergence-ledger account for
    # it, in the team's own namespace.
    for member in (alice, bob):
        keys = {
            str(row["key"])
            for row in member.engine.conn.execute(
                "SELECT key FROM engine_meta WHERE key LIKE 'sync_identity:team:%'"
            ).fetchall()
        }
        assert keys == {
            member.engine._sync_identity_key(TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY), TEAM_ID)
        }


def test_neither_members_personal_rows_are_touched_by_the_team_lane(team) -> None:
    """The isolation invariant, on the one path most likely to violate it.

    Alice's personal row and the team row carry the SAME body — she is the
    author — so if any part of this lane keyed on `(scope, body_hash)` without
    the team namespace, hers is the row it would claim. Bob's private note is
    the control: a body no team document ever carried.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    b_private = _remember_and_approve(bob, SECOND_BODY)
    before = {"alice": _row_state(alice, a_mid), "bob": _row_state(bob, b_private)}

    _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    _pull(bob, cloud, team_id=TEAM_ID)
    _pull(alice, cloud, team_id=TEAM_ID)

    assert _row_state(alice, a_mid) == before["alice"]
    assert _row_state(bob, b_private) == before["bob"]

    # Alice now holds two rows for one body — hers and the team's — in two
    # project partitions, and only the team one carries provenance.
    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY))
    assert landed != a_mid
    assert _team_row_ids(alice) == {landed}
    assert _team_row_ids(bob) == {landed}
    assert a_mid not in _team_row_ids(alice)
    assert b_private not in _team_row_ids(bob)

    # And Alice's own copy is still hers to edit; the team's is not.
    assert alice.engine.update(a_mid, text="The merge queue is the only path to main, always.")["status"] == "ok"
    refused = alice.engine.update(landed, text="rewritten by a local user")
    assert refused["status"] == "denied"
    assert refused["code"] in ("TEAM_ROW_NOT_WRITABLE", "TEAM_PROJECT_NOT_LINKED")


# ---------------------------------------------------------------------------
# 3. The negative: the mitigation is load-bearing
# ---------------------------------------------------------------------------


def test_a_teamProjectId_that_differs_between_the_checkouts_converges_nothing(team) -> None:
    """The failure mode the checked-in id prevents, made visible.

    Same repository, same fact, same team — and one character of difference in
    the committed link file. Two documents, two doc ids, and each member's pull
    refuses the other's for `TEAM_PROJECT_NOT_LINKED`. Nothing errors on the
    upload side, which is exactly why this had to be tested rather than reasoned
    about.
    """
    alice, bob, cloud = team
    _write_link(bob.root, {TEAM_ID: OTHER_TEAM_PROJECT_ID})

    a_mid = _remember_and_approve(alice, FACT_BODY)
    b_mid = _remember_and_approve(bob, FACT_BODY)
    a_doc = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    b_doc = _push(bob, cloud, b_mid, team_id=TEAM_ID, updated_at=T2)

    assert a_doc != b_doc
    assert len(cloud.docs) == 2, "the team space silently holds two documents for one fact"

    bob_pull = _pull(bob, cloud, team_id=TEAM_ID)
    assert bob_pull["refusedNotLinked"] == [a_doc]
    assert bob_pull["applied"] == 1

    alice_pull = _pull(alice, cloud, team_id=TEAM_ID)
    assert alice_pull["refusedNotLinked"] == [b_doc]
    assert alice_pull["applied"] == 1

    # Two rows, two landing partitions, no convergence anywhere.
    alice_rows = _team_row_ids(alice)
    bob_rows = _team_row_ids(bob)
    assert len(alice_rows) == len(bob_rows) == 1
    assert alice_rows != bob_rows
    body_hash = canonical_body_hash(FACT_BODY)
    assert alice_rows == {me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", body_hash)}
    assert bob_rows == {me.MemoryEngine._team_local_memory_id(TEAM_ID, OTHER_TEAM_PROJECT_ID, "personal", body_hash)}


def test_a_checkout_that_links_nothing_contributes_and_receives_nothing(team) -> None:
    """No entry for a team is the default, and it means silence in both directions."""
    alice, bob, cloud = team
    _write_link(bob.root, None)

    a_mid = _remember_and_approve(alice, FACT_BODY)
    a_doc = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)

    assert _team_project_id_for(bob, TEAM_ID) is None
    bob_pull = _pull(bob, cloud, team_id=TEAM_ID)
    assert bob_pull["refusedNotLinked"] == [a_doc]
    assert _team_row_ids(bob) == set()

    b_mid = _remember_and_approve(bob, SECOND_BODY)
    with pytest.raises(AssertionError):
        _seal(bob, b_mid, team_id=TEAM_ID, updated_at=T2)


def test_a_project_scoped_team_fact_lands_and_reaches_the_checkout_that_links_it(team) -> None:
    """The residual this proof found, and the ruling that closed it (amendment A1).

    As first written this test asserted the DEFECT, deliberately and at length:
    a team document seals its own `engineScope`, a team row lands in the
    `teamProjectId` partition — `burnbar-core`, the checked-in name, which is
    NOT any local engine project id (that is the whole mitigation) — and the
    engine's pre-existing per-project fence admitted a non-personal row only
    when `memory.project_id == session project_id`. Two namespaces, never equal.
    So a `project`-scoped team contribution uploaded cleanly, verified cleanly,
    merged cleanly, was addressable by id, and appeared in `recall`,
    `recall_pack`, `ask`, the session briefing, `list`, `entities` and
    `relations` on NO member's Mac, its author's included. No error anywhere,
    which is why only an end-to-end test could find it.

    That test said: "Widening the project fence for linked team rows is a
    serving change ... left to a ruling rather than taken here. If that ruling
    lands, this test is the one that must change, deliberately." The ruling
    landed — amendment A1, PR #2544, which cites this proof as what found it —
    so this is that deliberate change, and the assertions are inverted rather
    than deleted.

    A1's rule, and now the only thing deciding a team row: servable IFF this
    checkout's committed `.openburnbar/project.json` links that team to exactly
    the `teamProjectId` the row landed in. Bob's checkout does, so Bob is served
    the row; unlink it and the next call stops serving it, with no pull, no
    re-merge and no deletion — the D16 Cursor ruling's clause 2 and A1 meeting on
    one row.

    The negative properties A1 preserves have their own six tests in
    `test_memory_blind_sync.py`. What is proved HERE, and only here, is that the
    corrected rule holds on a row that travelled the whole two-clone path.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY, scope="project")
    _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    merged = _pull(bob, cloud, team_id=TEAM_ID)
    assert merged["applied"] == 1, merged

    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "project", canonical_body_hash(FACT_BODY))
    assert _team_row_ids(bob) == {landed}

    # It landed in the TEAM's partition, not in either checkout's local id —
    # the pre-condition that made the old fence unsatisfiable.
    row = bob.engine.conn.execute("SELECT project_id FROM memories WHERE id = ?", (landed,)).fetchone()
    assert str(row["project_id"]) == TEAM_PROJECT_ID
    assert TEAM_PROJECT_ID not in {alice.engine_project_id, bob.engine_project_id}

    # Addressable by id: `get` carries no project partition.
    import os

    cwd = os.getcwd()
    try:
        os.chdir(str(bob.root))
        assert bob.engine.get(landed)["status"] == "ok"
    finally:
        os.chdir(cwd)

    # And present on every surface that puts a row in front of a model.
    assert landed in _recalled_ids(bob, "merge queue main")
    assert landed in {str(item["memoryID"]) for item in bob.engine.list(project_path=str(bob.root))["results"]}
    assert "only path to main" in bob.engine.recall_pack("merge queue main", project_path=str(bob.root))["pack"]

    # The AUTHOR is served the team row too, once she pulls her own document
    # back — the half of the defect that made it impossible to notice by using
    # the feature, since the contributor saw nothing either.
    assert _pull(alice, cloud, team_id=TEAM_ID)["applied"] == 1
    assert landed in _team_row_ids(alice)
    assert landed in _recalled_ids(alice, "merge queue main")

    # The personal-scoped twin behaves identically now. Before A1 this line was
    # the ONLY one of the two that passed, and that asymmetry was the residual.
    a_personal = _remember_and_approve(alice, SECOND_BODY, scope="personal")
    _push(alice, cloud, a_personal, team_id=TEAM_ID, updated_at=T2)
    assert _pull(bob, cloud, team_id=TEAM_ID)["applied"] == 1
    personal_landed = me.MemoryEngine._team_local_memory_id(
        TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(SECOND_BODY)
    )
    assert personal_landed in _recalled_ids(bob, "nightly builds merge gate")

    # Unlinking stops both on the very next call. The rows are still in the
    # store — this is a serving fence, not a delete — and no pull ran.
    _write_link(bob.root, None)
    assert _team_row_ids(bob) == {landed, personal_landed}
    assert landed not in _recalled_ids(bob, "merge queue main")
    assert personal_landed not in _recalled_ids(bob, "nightly builds merge gate")
    assert landed not in {str(item["memoryID"]) for item in bob.engine.list(project_path=str(bob.root))["results"]}


# ---------------------------------------------------------------------------
# 4. Mutation: point the derivation at the git fingerprint and watch it die
# ---------------------------------------------------------------------------


def test_deriving_the_doc_id_from_the_git_fingerprint_breaks_the_proof(team, monkeypatch: pytest.MonkeyPatch) -> None:
    """The mutation, run in-suite so the proof cannot quietly stop proving.

    `_team_project_id_for` is the mitigation. Replace it with the git identity —
    the thing the design refused — and every property above inverts at once:

      * two document ids for one fact, so the team space holds two documents;
      * each member's pull refuses the OTHER's document for the pull-side link
        check, because a sealed `proj_<their git hash>` is not what this
        checkout links; and
      * each member's pull refuses their OWN document too, as a CROSS-NAMESPACE
        landing — the sealed `projectID` is now this member's real project, so
        `(project, scope, bodyHash)` is already held by the member's own
        PERSONAL row and `_decide_team_fact` refuses to let a team document take
        it. The isolation invariant catches what the derivation lost.

    Net: nothing converges and nothing lands, on either Mac, while every upload
    reports success. That silence is the whole danger the checked-in id exists
    to remove.

    Run by hand — editing `_team_project_id_for`'s body to
    `return member.engine_project_id` — the same change turns SIXTEEN of this
    file's twenty-five tests red, measured, not estimated: eight of the nine
    convergence tests above, and eight more among the link-tool, doctor and
    committed-link tests that need a real checked-in id to mean anything. The
    convergence test that survives is the one that must —
    `test_an_ssh_clone_and_an_https_clone_derive_different_git_project_ids`
    asserts the premise and is indifferent to the derivation — as does this
    test, which asserts the divergence the mutation causes.
    """
    alice, bob, cloud = team
    monkeypatch.setattr(sys.modules[__name__], "_team_project_id_for", _git_fingerprint_project_id)

    a_mid = _remember_and_approve(alice, FACT_BODY)
    b_mid = _remember_and_approve(bob, FACT_BODY)
    a_doc = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    b_doc = _push(bob, cloud, b_mid, team_id=TEAM_ID, updated_at=T2)

    assert a_doc != b_doc, "the mutation did not take: the derivation is not reading this function"
    assert len(cloud.docs) == 2

    bob_pull = _pull(bob, cloud, team_id=TEAM_ID)
    assert bob_pull["refusedNotLinked"] == [a_doc]
    assert bob_pull["applied"] == 0
    assert [d["code"] for d in bob_pull["decisions"]] == ["NAMESPACE_MISMATCH"]

    alice_pull = _pull(alice, cloud, team_id=TEAM_ID)
    assert alice_pull["refusedNotLinked"] == [b_doc]
    assert alice_pull["applied"] == 0
    assert [d["code"] for d in alice_pull["decisions"]] == ["NAMESPACE_MISMATCH"]

    assert _team_row_ids(alice) == set()
    assert _team_row_ids(bob) == set()


# ---------------------------------------------------------------------------
# 5. The link file's writer and its diagnostic (the second D16 follow-up)
# ---------------------------------------------------------------------------
#
# The file above is checked in by hand in every test so far, which is exactly
# how it worked before this PR: no writer, no diagnostic, and a mislinked
# repository showing up as an empty team space with no explanation anywhere.
# These cases drive the same convergence through the tool instead.


class _NoopContext:
    """Hand the server tools an engine the test owns, without closing it."""

    def __init__(self, engine: me.MemoryEngine) -> None:
        self._engine = engine

    def __enter__(self) -> me.MemoryEngine:
        return self._engine

    def __exit__(self, *_exc: object) -> bool:
        return False


def _read_link_file(root: Path) -> dict[str, object]:
    return json.loads((root / ".openburnbar" / "project.json").read_text(encoding="utf-8"))


def test_the_link_tool_is_gated_by_memory_write(team, server_env: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Writing the link file is a write, and it is gated like every other one.

    The link decides what this repository publishes to a team — a wider egress
    than any local row — so an agent granted nothing at all may not set it, for
    the same reason it may not run `burnbar_project_adopt`.
    """
    import server

    alice, _, _ = team
    monkeypatch.setattr(server, "_memory_engine", lambda: _NoopContext(alice.engine))
    denied = json.loads(
        server.burnbar_team_link_project(team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, project_path=str(alice.root))
    )
    assert denied["status"] == "denied"
    assert denied["capability"] == "memory_write"

    monkeypatch.setenv("OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE", "true")
    allowed = json.loads(
        server.burnbar_team_link_project(team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, project_path=str(alice.root))
    )
    assert allowed["status"] == "ok"
    assert allowed["event"] == "NONE"
    assert allowed["reason"] == "already_linked"


def test_the_link_tool_creates_the_file_and_the_two_clones_then_converge(team) -> None:
    """The whole point, driven through the writer: link, pull, converge.

    Bob's checkout starts publishing nothing — the default for every repository
    — so Alice's contribution is refused as `TEAM_PROJECT_NOT_LINKED` and his
    team space is empty. A confirmed call writes the file, a COMMIT makes it a
    link, the rewind-on-link rule re-offers what was refused, and the two clones
    land the same row id despite two different git project identities.

    The commit is a step in this test rather than an afterthought because it is
    a step in the product: the tool writes, the human commits, and only then is
    anything eligible (D16 Cursor ruling).
    """
    alice, bob, cloud = team
    _write_link(bob.root, None)

    a_mid = _remember_and_approve(alice, FACT_BODY)
    a_doc = _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    assert _pull(bob, cloud, team_id=TEAM_ID)["refusedNotLinked"] == [a_doc]
    assert _team_row_ids(bob) == set()

    linked = bob.engine.link_team_project(
        project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, confirmed=True
    )
    assert linked["status"] == "ok"
    assert linked["event"] == "LINKED"
    assert linked["teamID"] == TEAM_ID
    assert linked["teamProjectID"] == TEAM_PROJECT_ID
    assert linked["previousTeamProjectID"] is None
    assert linked["teams"] == {TEAM_ID: TEAM_PROJECT_ID}
    # Written but not committed, and the tool says so twice over: an untracked
    # link publishes to this Mac and nowhere else, and an uncommitted one is not
    # a link even here.
    assert linked["trackedByGit"] is False
    assert linked["effective"] is False
    assert linked["committedTeamProjectID"] is None
    assert "commit" in str(linked["nextStep"])
    assert _read_link_file(bob.root) == {"teams": {TEAM_ID: {"teamProjectId": TEAM_PROJECT_ID}}}

    # And it really does nothing yet. Rewinding the cursor the way the pull does
    # on a new link changes nothing, because there is no new link.
    bob.pull_cursor = ""
    assert _pull(bob, cloud, team_id=TEAM_ID)["refusedNotLinked"] == [a_doc]
    assert _team_row_ids(bob) == set()

    _commit_link(bob.root)
    assert bob.engine._link_file_tracked(bob.root) is True

    # The link is live on the next call, with nothing restarted: the reader is
    # not cached. Rewind the cursor the way the pull does when the link set
    # gains an id, and everything refused before the link lands.
    bob.pull_cursor = ""
    assert _pull(bob, cloud, team_id=TEAM_ID)["applied"] == 1
    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY))
    assert _team_row_ids(bob) == {landed}
    assert landed in _recalled_ids(bob, "merge queue main")

    # Re-running the tool on the committed link is the reported no-op, and it
    # now says the entry is effective.
    again = bob.engine.link_team_project(project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID)
    assert again["event"] == "NONE"
    assert again["effective"] is True


def test_the_link_tool_refuses_to_clobber_a_different_id_without_confirm(team) -> None:
    """Re-pointing a link moves every future document of that team. Ask first.

    `burnbar_project_adopt`'s pattern, for the same reason: the existing value
    may be a teammate's commit, and re-pointing it silently would split the
    team's space exactly the way the git fingerprint would have.
    """
    alice, _, _ = team
    refused = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=TEAM_ID, team_project_id=OTHER_TEAM_PROJECT_ID
    )
    assert refused["status"] == "refused"
    assert refused["code"] == "LINK_ALREADY_SET"
    assert refused["currentTeamProjectID"] == TEAM_PROJECT_ID
    assert refused["proposedTeamProjectID"] == OTHER_TEAM_PROJECT_ID
    assert _read_link_file(alice.root)["teams"] == {TEAM_ID: {"teamProjectId": TEAM_PROJECT_ID}}

    relinked = alice.engine.link_team_project(
        project_path=str(alice.root),
        team_id=TEAM_ID,
        team_project_id=OTHER_TEAM_PROJECT_ID,
        confirmed=True,
    )
    assert relinked["event"] == "RELINKED"
    assert relinked["previousTeamProjectID"] == TEAM_PROJECT_ID
    # A confirmed re-point is still only a written file: HEAD still names the
    # old id, so the OLD link is what is honoured until the change is committed
    # — and per the intersection rule, a disagreement is no link at all.
    assert relinked["effective"] is False
    assert relinked["committedTeamProjectID"] == TEAM_PROJECT_ID
    assert _team_project_id_for(alice, TEAM_ID) is None
    _commit_link(alice.root)
    assert _team_project_id_for(alice, TEAM_ID) == OTHER_TEAM_PROJECT_ID

    # An unchanged value needs no confirmation and changes nothing.
    again = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=TEAM_ID, team_project_id=OTHER_TEAM_PROJECT_ID
    )
    assert again["event"] == "NONE"
    assert again["reason"] == "already_linked"


def test_the_link_tool_screens_both_ids_the_way_the_reader_screens_them(team) -> None:
    """A value this writer accepts and the reader drops would be a phantom link."""
    alice, _, _ = team
    other_team = "team_fedcba9876543210"

    bad_team = alice.engine.link_team_project(
        project_path=str(alice.root), team_id="team_NOTHEX", team_project_id="burnbar-ios"
    )
    assert bad_team["status"] == "refused"
    assert bad_team["code"] == "INVALID_TEAM_ID"

    bad_project = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=other_team, team_project_id="has spaces and | pipes"
    )
    assert bad_project["status"] == "refused"
    assert bad_project["code"] == "INVALID_TEAM_PROJECT_ID"

    over_bound = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=other_team, team_project_id="a" * 129
    )
    assert over_bound["code"] == "INVALID_TEAM_PROJECT_ID"

    # Nothing was written by any of them, and the good entry is untouched.
    assert _read_link_file(alice.root)["teams"] == {TEAM_ID: {"teamProjectId": TEAM_PROJECT_ID}}

    # A second team is ADDED beside the first, never instead of it.
    added = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=other_team, team_project_id="burnbar-ios", confirmed=True
    )
    assert added["event"] == "LINKED"
    assert added["teams"] == {TEAM_ID: TEAM_PROJECT_ID, other_team: "burnbar-ios"}
    assert _team_project_id_for(alice, TEAM_ID) == TEAM_PROJECT_ID


def test_the_link_tool_never_overwrites_a_link_file_it_cannot_parse(team) -> None:
    """A damaged file may hold another team's entry. It is reported, never rewritten."""
    alice, _, _ = team
    path = alice.root / ".openburnbar" / "project.json"
    path.write_text("{ this is not json", encoding="utf-8")

    for confirm in (False, True):
        refused = alice.engine.link_team_project(
            project_path=str(alice.root),
            team_id=TEAM_ID,
            team_project_id=TEAM_PROJECT_ID,
            confirmed=confirm,
        )
        assert refused["status"] == "refused"
        assert refused["code"] == "LINK_FILE_UNREADABLE"
        assert refused["path"] == str(path)
    assert path.read_text(encoding="utf-8") == "{ this is not json"

    # Oversized reads the same way, and for the same reason: the reader refuses
    # such a file WHOLE, so the repository already publishes nothing.
    path.write_text(json.dumps({"teams": {}, "pad": "x" * 4096}), encoding="utf-8")
    assert (
        alice.engine.link_team_project(project_path=str(alice.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID)[
            "code"
        ]
        == "LINK_FILE_UNREADABLE"
    )


def _link_finding(engine: me.MemoryEngine, root: Path) -> dict[str, object] | None:
    report = engine.doctor(project_path=str(root))
    for finding in report["findings"]:
        if finding.get("code") == "TEAM_PROJECT_LINK_GAPS":
            return finding
    return None


def test_the_doctor_explains_an_empty_team_space_instead_of_leaving_it_silent(team) -> None:
    """The finding this follow-up exists for: a member removes a link and asks why.

    Before it, unlinking produced silence on every surface — the serving fence
    refuses without saying so, by design, and the pull-side refusal is a Swift
    log dimension the engine cannot see. Now the doctor names the team, counts
    the rows being withheld, and names the tool that fixes it.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    assert _pull(bob, cloud, team_id=TEAM_ID)["applied"] == 1
    assert _link_finding(bob.engine, bob.root) is None, "a correctly linked checkout is not a finding"

    _write_link(bob.root, None)
    finding = _link_finding(bob.engine, bob.root)
    assert finding is not None
    assert finding["severity"] == "warn"
    assert finding["linkPath"] == str(bob.root / ".openburnbar" / "project.json")
    assert "burnbar_team_link_project" in str(finding["fix"])
    assert "COMMIT" in str(finding["fix"])

    teams = {str(item["teamID"]): item for item in finding["teams"]}
    assert set(teams) == {TEAM_ID}
    entry = teams[TEAM_ID]
    assert entry["linkedInThisCheckout"] is False
    assert entry["linkedTeamProjectID"] is None
    assert entry["factsHeldLocally"] == 1
    assert entry["factsWithheldTeamProjectNotLinked"] == 1
    assert entry["landingProjectIDs"] == [TEAM_PROJECT_ID]

    # Counts and ids, never bodies — the ORPHAN_TEAM_PROVENANCE contract.
    assert FACT_BODY not in json.dumps(finding)
    assert "merge queue" not in json.dumps(finding)

    # And it clears the moment the link comes back — which takes the write AND
    # the commit, because the write alone changes nothing the fences read. The
    # intermediate state is its own finding, asserted in
    # `test_the_doctor_reports_an_uncommitted_link_as_uncommitted_not_as_linked`.
    bob.engine.link_team_project(
        project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, confirmed=True
    )
    assert _link_finding(bob.engine, bob.root) is not None
    _commit_link(bob.root)
    assert _link_finding(bob.engine, bob.root) is None


def test_the_doctor_flags_a_link_that_names_a_partition_none_of_the_held_facts_are_in(team) -> None:
    """The typo case: the link is present, well-formed, and points one character away.

    This is the state that produced the original complaint — a team space that
    empties itself with no explanation. The qualifier is what makes the finding
    worth reading: a link with no rows behind it yet is a brand-new correct link
    as often as a typo, and nothing local can tell those apart, so the doctor
    stays quiet until the store actually holds facts the link disagrees with.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    assert _pull(bob, cloud, team_id=TEAM_ID)["applied"] == 1
    assert _link_finding(bob.engine, bob.root) is None

    _write_link(bob.root, {TEAM_ID: "burbnar-core"})  # one transposition
    finding = _link_finding(bob.engine, bob.root)
    assert finding is not None
    entry = {str(item["teamID"]): item for item in finding["teams"]}[TEAM_ID]
    assert entry["linkedInThisCheckout"] is True
    assert entry["linkedTeamProjectID"] == "burbnar-core"
    assert entry["linkNamesNoHeldPartition"] is True
    assert entry["landingProjectIDs"] == [TEAM_PROJECT_ID]
    assert entry["factsHeldLocally"] == 1
    assert entry["factsWithheldTeamProjectNotLinked"] == 1
    assert "none of the" in str(finding["detail"])

    # A link with nothing behind it yet is NOT a finding — that is a fresh
    # checkout, not a mistake, and crying wolf there would make the whole
    # report ignorable.
    quiet_alice = alice.engine.doctor(project_path=str(alice.root))
    assert not [f for f in quiet_alice["findings"] if f.get("code") == "TEAM_PROJECT_LINK_GAPS"]


def test_the_doctor_names_a_team_this_mac_syncs_and_this_checkout_does_not_link(team) -> None:
    """The roster/opt-in half: `remote_sync_watermarks` is the local evidence.

    The app writes a `team:<teamId>:<uid>` account key for every team it syncs —
    the pull cursor, the push watermark and the link records all share it — so a
    team with a key here and no entry in this repository is a team the member
    opted in to and never told this repository about.
    """
    alice, _, _ = team
    other_team = "team_fedcba9876543210"
    alice.engine.conn.execute(
        "CREATE TABLE IF NOT EXISTS remote_sync_watermarks ("
        "accountUid TEXT NOT NULL, collectionKind TEXT NOT NULL, lastSyncedAt TEXT NOT NULL, "
        "lastProcessedRemoteUpdateAt TEXT, version INTEGER NOT NULL DEFAULT 1, "
        "PRIMARY KEY (accountUid, collectionKind))"
    )
    alice.engine.conn.execute(
        "INSERT INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt) VALUES (?, ?, ?)",
        (f"team:{other_team}:{UID_A}", "memory_facts_team", T1),
    )
    alice.engine.conn.commit()

    finding = _link_finding(alice.engine, alice.root)
    assert finding is not None
    teams = {str(item["teamID"]): item for item in finding["teams"]}
    assert teams[other_team]["syncedOnThisMac"] is True
    assert teams[other_team]["linkedInThisCheckout"] is False
    assert teams[other_team]["factsHeldLocally"] == 0
    # The correctly linked team is reported in the reader's own map but is not
    # one of the teams the finding flags.
    assert TEAM_ID not in teams
    assert alice.engine.team_project_link_report(str(alice.root))["links"] == {TEAM_ID: TEAM_PROJECT_ID}


def test_the_doctor_never_writes_the_link_file_even_with_apply(team) -> None:
    """No `apply`. The link is a checked-in, human decision, not a repair.

    `doctor(apply=True)` prunes aged orphans, resets parked supersedes and
    un-stamps forged provenance. Writing a link would be committing on the
    member's behalf, in a file a teammate reads.
    """
    alice, _, _ = team
    _write_link(alice.root, None)
    path = alice.root / ".openburnbar" / "project.json"

    report = alice.engine.doctor(project_path=str(alice.root), apply=True)
    assert report["apply"]["applied"] is True
    assert not path.exists()
    assert "linkFile" not in report["apply"]


# ---------------------------------------------------------------------------
# 5. The D16 Cursor ruling: a link is a COMMITTED, CONFIRMED, human decision
# ---------------------------------------------------------------------------
#
# The finding (HIGH, PR #2542): a first-time `link_team_project` write went
# through with `confirmed=False`, only a re-point was gated, `doctor` was
# ungated and flagged the ordinary `syncedOnThisMac && !linkedInThisCheckout`
# state with a `fix` naming the tool, and both link readers used the WORKING
# TREE. So anything able to write a file in a private checkout on a Mac that
# already syncs a team — an agent, a prompt-injected tool call — could opt that
# repository in without a human confirmation and without a commit, and its
# approved memories became eligible to upload under the teammates' agreed
# `teamProjectId`.
#
# The ruling, in three clauses, and one test per clause plus the reproduction
# the finding described:
#
#   1. every write is confirmed, not only a re-point;
#   2. eligibility follows the COMMITTED link, failing closed on no HEAD, on an
#      uncommitted entry and on a committed-then-modified one;
#   3. the doctor reports the gap and says what linking DOES, and stays a
#      report rather than a remediation script.


def _bob_syncs_the_team(bob: _Member) -> None:
    """The precondition the finding names: this Mac already syncs this team.

    A `team:<teamId>:<uid>` account key in `remote_sync_watermarks` is the local
    evidence of an opt-in, which is what makes an unconfirmed link in a PRIVATE
    checkout an egress rather than a no-op.
    """
    bob.engine.conn.execute(
        "CREATE TABLE IF NOT EXISTS remote_sync_watermarks ("
        "accountUid TEXT NOT NULL, collectionKind TEXT NOT NULL, lastSyncedAt TEXT NOT NULL, "
        "lastProcessedRemoteUpdateAt TEXT, version INTEGER NOT NULL DEFAULT 1, "
        "PRIMARY KEY (accountUid, collectionKind))"
    )
    bob.engine.conn.execute(
        "INSERT OR REPLACE INTO remote_sync_watermarks (accountUid, collectionKind, lastSyncedAt) VALUES (?, ?, ?)",
        (f"team:{TEAM_ID}:{UID_B}", "memory_facts_team", T1),
    )
    bob.engine.conn.commit()


def test_an_unconfirmed_uncommitted_link_makes_nothing_uploadable(team) -> None:
    """THE REPORTED PATH, end to end, as the thing that must not happen.

    Bob's Mac already syncs the team. His private checkout links nothing, and he
    has a private, approved memory in it. A tool call — his, or one an injected
    instruction talked an agent into — asks for the link with no confirmation
    and commits nothing.

    Before the ruling both halves of that succeeded and the memory became
    eligible to upload under the team's agreed `teamProjectId`. Now the write is
    refused for want of a confirmation, and even a confirmed write leaves the
    repository publishing nothing until a human commits it. Two independent
    stops, because each closes a different half of the finding.
    """
    _, bob, cloud = team
    _bob_syncs_the_team(bob)
    _write_link(bob.root, None)
    private = _remember_and_approve(bob, SECOND_BODY)

    # (1) The unconfirmed write is refused, and it says what it would have done.
    refused = bob.engine.link_team_project(project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID)
    assert refused["status"] == "refused"
    assert refused["code"] == "LINK_REQUIRES_CONFIRMATION"
    assert "eligible to upload" in str(refused["reason"])
    assert not (bob.root / ".openburnbar" / "project.json").exists()
    assert _team_project_id_for(bob, TEAM_ID) is None

    # (2) And confirmation alone is not the link either. The file is written,
    # nothing is committed, and the repository still publishes nothing — so the
    # private memory has no landing partition and cannot be sealed at all.
    written = bob.engine.link_team_project(
        project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, confirmed=True
    )
    assert written["status"] == "ok"
    assert written["effective"] is False
    assert _team_project_id_for(bob, TEAM_ID) is None
    with pytest.raises(AssertionError):
        _seal(bob, private, team_id=TEAM_ID, updated_at=T2)
    assert cloud.docs == {}

    # The commit is the decision, and it is the only thing that was missing.
    _commit_link(bob.root)
    assert _team_project_id_for(bob, TEAM_ID) == TEAM_PROJECT_ID


def test_a_first_time_link_is_refused_without_confirm(team) -> None:
    """Ruling clause 1. The FIRST write is the one that opens the door.

    The original gate fired only on a re-point, on the reasoning that creating
    an entry destroys nothing. True, and beside the point: what is at stake is
    not the file's previous contents but what the file makes publishable, and on
    a Mac already syncing the team the first write is exactly the write that
    publishes. Both refusals now exist, they carry different codes because they
    are different decisions, and neither writes a byte.
    """
    alice, bob, _ = team
    _write_link(bob.root, None)
    path = bob.root / ".openburnbar" / "project.json"

    first = bob.engine.link_team_project(project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID)
    assert first["status"] == "refused"
    assert first["code"] == "LINK_REQUIRES_CONFIRMATION"
    assert first["proposedTeamProjectID"] == TEAM_PROJECT_ID
    assert "confirm=true" in str(first["reason"])
    assert "COMMIT" in str(first["reason"])
    assert not path.exists(), "a refused write writes nothing, not even an empty file"

    # A re-point keeps its own code and reports both sides — a member who meant
    # to create a link should learn that one already exists, not just that they
    # forgot a flag.
    repoint = alice.engine.link_team_project(
        project_path=str(alice.root), team_id=TEAM_ID, team_project_id=OTHER_TEAM_PROJECT_ID
    )
    assert repoint["code"] == "LINK_ALREADY_SET"
    assert repoint["currentTeamProjectID"] == TEAM_PROJECT_ID

    # And the confirmed first write goes through, so the gate is a gate and not
    # a wall.
    assert (
        bob.engine.link_team_project(
            project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID, confirmed=True
        )["event"]
        == "LINKED"
    )
    assert path.is_file()


def test_only_a_committed_link_makes_a_project_eligible(team) -> None:
    """Ruling clause 2, in its four states, on the shipped reader.

    committed -> a link; working tree only -> not; committed then modified ->
    not, in both directions; no git HEAD at all -> not. Every negative is a
    fail-closed answer, and the last one is the ruling's named case: a directory
    with nothing checked in has checked in no decision.
    """
    alice, bob, _ = team

    # Committed: the fixture's own state, and the only one that links.
    assert _team_project_id_for(bob, TEAM_ID) == TEAM_PROJECT_ID
    links = bob.engine._session_team_links(bob.engine_project_id)
    assert links.teams == {TEAM_ID: TEAM_PROJECT_ID}
    assert links.committed == {TEAM_ID: TEAM_PROJECT_ID}

    # Working tree only.
    _write_link(bob.root, None)
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID}, commit=False)
    links = bob.engine._session_team_links(bob.engine_project_id)
    assert links.teams == {}
    assert links.working_tree == {TEAM_ID: TEAM_PROJECT_ID}
    assert links.committed == {}

    # Committed, then modified: the working tree names a different id than HEAD.
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID})
    _write_link(bob.root, {TEAM_ID: OTHER_TEAM_PROJECT_ID}, commit=False)
    links = bob.engine._session_team_links(bob.engine_project_id)
    assert links.teams == {}, "a modified entry is neither the old link nor the new one"
    assert links.working_tree == {TEAM_ID: OTHER_TEAM_PROJECT_ID}
    assert links.committed == {TEAM_ID: TEAM_PROJECT_ID}

    # Modified the other way: HEAD still carries it, the member deleted it
    # locally. The fence has always had to stop serving the instant a link is
    # taken away, without waiting for a commit, and it still does.
    _write_link(bob.root, None, commit=False)
    assert bob.engine._session_team_links(bob.engine_project_id).teams == {}

    # Per entry, not per file: an in-progress edit adding a second team must not
    # silently unlink the first, whose entry HEAD carries and the team agreed to.
    other_team = "team_fedcba9876543210"
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID})
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID, other_team: "burnbar-ios"}, commit=False)
    assert bob.engine._session_team_links(bob.engine_project_id).teams == {TEAM_ID: TEAM_PROJECT_ID}

    # No git HEAD at all: same bytes, same path, no repository. Fail closed.
    bare = alice.root.parent / "not_a_repo"
    bare.mkdir()
    (bare / ".openburnbar").mkdir()
    (bare / ".openburnbar" / "project.json").write_text(
        json.dumps({"teams": {TEAM_ID: {"teamProjectId": TEAM_PROJECT_ID}}}), encoding="utf-8"
    )
    bare_project = me.resolve_project(alice.engine.conn, str(bare))[0]
    bare_links = alice.engine._session_team_links(bare_project)
    assert bare_links.working_tree == {TEAM_ID: TEAM_PROJECT_ID}
    assert bare_links.teams == {}


def test_an_uncommitted_link_serves_no_team_row_into_this_session(team) -> None:
    """Ruling clause 2 on the READ half, with a real row rather than a map.

    The finding's second sentence: "the T4 serving fence for this session opens
    on the next recall". It does not, now. Bob holds a team row landed under the
    agreed partition; unlinking and re-writing the entry WITHOUT committing must
    leave that row unserved on every path the fence covers.
    """
    alice, bob, cloud = team
    a_mid = _remember_and_approve(alice, FACT_BODY)
    _push(alice, cloud, a_mid, team_id=TEAM_ID, updated_at=T1)
    assert _pull(bob, cloud, team_id=TEAM_ID)["applied"] == 1
    landed = me.MemoryEngine._team_local_memory_id(TEAM_ID, TEAM_PROJECT_ID, "personal", canonical_body_hash(FACT_BODY))
    assert landed in _recalled_ids(bob, "merge queue main")

    _write_link(bob.root, None)
    assert landed not in _recalled_ids(bob, "merge queue main")

    # Re-written in the working tree and not committed: the row stays held back,
    # and so does every other serving path.
    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID}, commit=False)
    assert landed not in _recalled_ids(bob, "merge queue main")
    assert not bob.engine._team_serves_memory(landed, bob.engine_project_id)
    exported = bob.engine.export(project_path=str(bob.root))
    assert landed not in json.dumps(exported)
    assert FACT_BODY not in json.dumps(exported)

    _commit_link(bob.root)
    assert landed in _recalled_ids(bob, "merge queue main")


def test_the_doctor_reports_an_uncommitted_link_as_uncommitted_not_as_linked(team) -> None:
    """Ruling clause 3. The two states are different sentences, so they read differently.

    A written-and-uncommitted entry is the ONE place the working-tree read stays
    honest — "you wrote this and did not commit it" is true and worth saying —
    and it is reported as its own dimension rather than folded into either
    "linked" (which it is not) or a bare "no entry" (which loses what the member
    actually did).
    """
    _, bob, _ = team
    _bob_syncs_the_team(bob)
    _write_link(bob.root, None)

    # Nothing written yet: the plain unlinked case.
    entry = {str(item["teamID"]): item for item in _link_finding(bob.engine, bob.root)["teams"]}[TEAM_ID]
    assert entry["linkedInThisCheckout"] is False
    assert entry["linkWrittenButNotCommitted"] is False
    assert entry["workingTreeTeamProjectID"] is None

    _write_link(bob.root, {TEAM_ID: TEAM_PROJECT_ID}, commit=False)
    finding = _link_finding(bob.engine, bob.root)
    assert finding is not None
    entry = {str(item["teamID"]): item for item in finding["teams"]}[TEAM_ID]
    assert entry["linkedInThisCheckout"] is False, "an uncommitted entry is not a link"
    assert entry["linkWrittenButNotCommitted"] is True
    assert entry["workingTreeTeamProjectID"] == TEAM_PROJECT_ID
    assert entry["committedTeamProjectID"] is None
    assert finding["uncommittedTeamIDs"] == [TEAM_ID]
    assert "never committed" in str(finding["detail"])

    # The finding says what linking DOES and whose decision it is, and it does
    # not read as a step to run because a report mentioned it.
    assert "eligible to upload" in str(finding["decision"])
    assert "human decision" in str(finding["decision"])
    assert "not a step to run" in str(finding["decision"])
    assert "human confirms" in str(finding["fix"])
    assert "COMMITS" in str(finding["fix"])
    assert "confirm=true" in str(finding["fix"])
    assert "apply" not in finding

    _commit_link(bob.root)
    assert _link_finding(bob.engine, bob.root) is None


def test_the_three_ruling_clauses_are_each_load_bearing(team, monkeypatch: pytest.MonkeyPatch) -> None:
    """One mutation per clause, each turning a NAMED test red.

    A clause that no test notices being removed is a clause that is not enforced,
    whatever the code says. Each mutation restores the pre-ruling behaviour of
    exactly one clause and the assertion that then fails is named beside it.
    """
    _, bob, _ = team
    _bob_syncs_the_team(bob)

    # Clause 1 — gate only the re-point again. Fails
    # `test_a_first_time_link_is_refused_without_confirm` and the first half of
    # `test_an_unconfirmed_uncommitted_link_makes_nothing_uploadable`.
    _write_link(bob.root, None)
    original = me.MemoryEngine.link_team_project

    def unconfirmed_first_write(self, **kwargs: object):
        return original(self, **{**kwargs, "confirmed": True})

    monkeypatch.setattr(me.MemoryEngine, "link_team_project", unconfirmed_first_write)
    assert (
        bob.engine.link_team_project(project_path=str(bob.root), team_id=TEAM_ID, team_project_id=TEAM_PROJECT_ID)[
            "status"
        ]
        == "ok"
    ), "clause 1 mutation must restore the unconfirmed first write"
    monkeypatch.undo()

    # Clause 2 — read the working tree again. The uncommitted file written just
    # above becomes a link, which is the finding. Fails
    # `test_only_a_committed_link_makes_a_project_eligible`,
    # `test_an_uncommitted_link_serves_no_team_row_into_this_session` and the
    # second half of the reproduction.
    assert bob.engine._session_team_links(bob.engine_project_id).teams == {}
    monkeypatch.setattr(
        me.MemoryEngine,
        "_committed_team_links",
        classmethod(lambda cls, root: cls._decode_team_links((root / ".openburnbar" / "project.json").read_bytes())),
    )
    assert bob.engine._session_team_links(bob.engine_project_id).teams == {TEAM_ID: TEAM_PROJECT_ID}, (
        "clause 2 mutation must restore the working-tree read"
    )
    monkeypatch.undo()

    # Clause 3 — collapse the uncommitted dimension back into the linked one.
    # Fails `test_the_doctor_reports_an_uncommitted_link_as_uncommitted_not_as_linked`.
    finding = _link_finding(bob.engine, bob.root)
    assert finding is not None
    assert finding["uncommittedTeamIDs"] == [TEAM_ID]
    report = bob.engine.team_project_link_report(str(bob.root))
    monkeypatch.setattr(
        me.MemoryEngine,
        "team_project_link_report",
        lambda self, project_path=None: {
            **report,
            "teams": [{**team_entry, "linkWrittenButNotCommitted": False} for team_entry in report["teams"]],
        },
    )
    collapsed = _link_finding(bob.engine, bob.root)
    assert collapsed is not None
    assert collapsed["uncommittedTeamIDs"] == [], "clause 3 mutation must hide the uncommitted dimension"
