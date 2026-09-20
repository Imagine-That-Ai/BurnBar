"""Every path that ENDS a row's life, and the one fence they share.

Retiring, folding and hard-deleting were spread across `_write.py` and
`_read.py` — the destructive half of a module named for reading, and the tail of
a module named for adding. PR3 Cursor ruling T5 gave them a reason to sit
together: they are exactly the surfaces a local user can point at an existing
row, and after T5 they answer to one predicate,
`_team_row_writable_by_local_user`. A team-origin row is never retired, folded
away or deleted by a write the local user initiated, in any session, linked or
not; it changes through the team lane or not at all. Keeping the callers of that
rule in one file is what makes "every one of them is fenced" checkable by
reading rather than by grepping.

`_history` travels with them because it is how a refusal is recorded: a blocked
retirement writes `retire_blocked_team` and nothing else, so the row's own
revision log carries the evidence that the fence fired.

Only methods live here; construction and shared state stay in `engine.py`."""

from __future__ import annotations

from typing import TYPE_CHECKING, Any

from ._util import _json_dumps, _json_loads, normalize_kind_strict, normalize_tags, now_iso, sha256_hex
from .constants import KINDS, TEAM_ID_JSON_PATH
from .store import audit_event, project_payload, resolve_project

if TYPE_CHECKING:  # pragma: no cover — annotations only
    from collections.abc import Sequence


class _Lifecycle:
    """Retire, fold and forget — the destructive surfaces, behind one fence."""

    def _retire(
        self,
        memory_id: str,
        *,
        reason: str,
        replacement: str | None,
        remote_at: str | None = None,
        team_scoped: bool = False,
    ) -> bool:
        """Close a row out. `remote_at` is the blind-sync merge: the retirement
        instant comes from the remote revision that caused it, and `updated_at` —
        the row's last *writer* mark, which last-writer-wins reads — is left
        alone, because a merge is not a local write. Stamping this device's clock
        there would make every remote revision authored before the merge ran look
        stale for ever.
        """
        row = self._get_row(memory_id)
        if row is None or row["valid_to"] is not None:
            return False
        # T5, defence in depth. `_team_write_filter` already keeps team rows out
        # of every candidate set that reaches here, so this should be
        # unreachable from `_commit_fact`; it is the fence for `fold` and for
        # whatever the next retirement caller turns out to be. `team_scoped` is
        # the merge saying "this retirement IS the team lane", which the two
        # `_sync.py` callers pass and no local path does.
        if not self._team_row_writable_by_local_user(
            self._metadata_team_id(_json_loads(row["metadata_json"], {}) or {}), team_scoped=team_scoped
        ):
            self._history(
                memory_id,
                str(row["project_id"]),
                "retire_blocked_team",
                None,
                None,
                {"reason": reason, "replacement": replacement},
            )
            return False
        if bool(row["immutable"]):
            self._history(
                memory_id,
                str(row["project_id"]),
                "retire_blocked_immutable",
                None,
                None,
                {"reason": reason, "replacement": replacement},
            )
            return False
        if remote_at is None:
            ts = now_iso()
            self.conn.execute(
                "UPDATE memories SET valid_to = ?, superseded_by = ?, updated_at = ? WHERE id = ?",
                (ts, replacement, ts, memory_id),
            )
        else:
            self.conn.execute(
                "UPDATE memories SET valid_to = ?, superseded_by = ? WHERE id = ?",
                (remote_at, replacement, memory_id),
            )
        self._history(
            memory_id, str(row["project_id"]), "retired", None, None, {"reason": reason, "replacement": replacement}
        )
        return True

    def _history(
        self, memory_id: str, project_id: str, event: str, before: str | None, after: str | None, meta: dict[str, Any]
    ) -> None:
        aad = f"{memory_id}|{project_id}|history"
        before_cipher = before_nonce = after_cipher = after_nonce = None
        if before is not None:
            before_cipher, before_nonce = self.keyring.seal(before, aad)
        if after is not None:
            after_cipher, after_nonce = self.keyring.seal(after, aad)
        self.conn.execute(
            "INSERT INTO memory_history (memory_id, project_id, event, actor, ts, before_cipher, before_nonce, after_cipher, after_nonce, key_id, meta_json) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (
                memory_id,
                project_id,
                event,
                self.config.actor,
                now_iso(),
                before_cipher,
                before_nonce,
                after_cipher,
                after_nonce,
                self.keyring.key_id,
                _json_dumps(meta),
            ),
        )

    def fold(
        self,
        folded_id: str,
        canonical_id: str | None = None,
        *,
        into: str | None = None,
        reason: str = "folded",
    ) -> dict[str, Any]:
        """Fold a memory id into a canonical row.

        Writes `memory_alias:<folded_id>` to engine_meta, retires `folded_id`
        if present in memories, and records a memory_history entry.
        """
        target = canonical_id or into
        if not target or not folded_id:
            return {"status": "error", "reason": "missing_ids"}
        if folded_id == target:
            return {"status": "ok", "event": "NONE", "reason": "self_fold_no_op", "memoryID": target}

        resolved_target = self._alias_target(target) or target
        target_row = self.conn.execute(
            "SELECT rowid, id, project_id, metadata_json, valid_to FROM memories WHERE id = ?", (resolved_target,)
        ).fetchone()
        if target_row is None:
            return {"status": "not_found", "memoryID": resolved_target}
        # T5. A fold retires one row and redirects its id at another for good —
        # the most destructive thing a local caller can do to a row short of
        # `forget` — so neither end of it may be a team row. Checked on both:
        # folding a team row away destroys it, and folding a personal row INTO
        # one rewrites the team row's `supersedes_json`.
        for candidate in (resolved_target, folded_id):
            refusal = self._team_write_refusal(candidate)
            if refusal is not None:
                return {"status": "denied", **refusal, "foldedID": folded_id}

        existing_alias = self._alias_target(folded_id)
        if existing_alias == resolved_target:
            return {
                "status": "ok",
                "event": "NONE",
                "reason": "already_folded",
                "memoryID": resolved_target,
                "foldedID": folded_id,
            }

        folded_row = self.conn.execute(
            "SELECT rowid, id, project_id, valid_to, metadata_json, tags_json FROM memories WHERE id = ?", (folded_id,)
        ).fetchone()
        # Written after the lookup, so the alias and the retirement it describes
        # happen together. A folded id with no local row is still legitimate —
        # a remote id folding into a local one is exactly that — but the alias
        # is no longer recorded before this method knows what it is folding.
        self._record_memory_alias(folded_id, resolved_target)
        if folded_row is not None and folded_row["valid_to"] is None:
            meta = _json_loads(folded_row["metadata_json"], {})
            meta["foldedInto"] = resolved_target
            tags = normalize_tags(list(_json_loads(folded_row["tags_json"], [])) + ["folded"])
            self.conn.execute(
                "UPDATE memories SET metadata_json = ?, tags_json = ? WHERE id = ?",
                (_json_dumps(meta), _json_dumps(tags), folded_id),
            )
            self._retire(folded_id, reason=reason, replacement=resolved_target)

        target_proj = str(target_row["project_id"])
        self._history(
            resolved_target,
            target_proj,
            "fold_absorbed",
            None,
            None,
            {"foldedID": folded_id, "reason": reason},
        )
        if folded_row is not None:
            self._history(
                folded_id,
                str(folded_row["project_id"]),
                "folded",
                None,
                None,
                {"canonicalID": resolved_target, "reason": reason},
            )

        if folded_row is not None:
            inv = self.conn.execute("SELECT supersedes_json FROM memories WHERE id = ?", (resolved_target,)).fetchone()
            if inv is not None:
                supersedes = sorted({*_json_loads(inv["supersedes_json"], []), folded_id})
                self.conn.execute(
                    "UPDATE memories SET supersedes_json = ? WHERE id = ?",
                    (_json_dumps(supersedes), resolved_target),
                )

        # A fold changes which row an id resolves to, for good. Every other
        # id-lifecycle decision — add, update, forget, sync add, resurrection
        # refused — leaves a label-only row in the hash chain; this one left
        # `memory_history` and nothing else, so the record of decisions did not
        # contain the redirection.
        audit_event(
            self.conn,
            project_id=target_proj,
            action="memory.fold",
            subject_id=resolved_target,
            labels=[f"folded:{folded_id}", f"reason:{reason}", "retired" if folded_row is not None else "alias_only"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "event": "FOLD",
            "canonicalID": resolved_target,
            "foldedID": folded_id,
            "reason": reason,
        }

    def forget(self, memory_id: str, *, project_path: str | None = None) -> dict[str, Any]:
        target_id = self._alias_target(memory_id) or memory_id
        row = self.conn.execute(
            "SELECT rowid, id, project_id, metadata_json, immutable FROM memories WHERE id = ?", (target_id,)
        ).fetchone()
        if row is None:
            return {"status": "not_found", "memoryID": memory_id}
        # T5, on the RESOLVED id: an alias is a redirection, and a forget that
        # followed one into a team row would be a hard delete of team memory
        # requested under a personal id.
        refusal = self._team_write_refusal(target_id, row=row, project_path=project_path)
        if refusal is not None:
            return {"status": "denied", **refusal}
        project_id = str(row["project_id"])
        canonical_id = str(row["id"])
        self._purge(canonical_id, int(row["rowid"]), preserve_daemon_mirror=True)
        if target_id != memory_id:
            folded_row = self.conn.execute("SELECT rowid FROM memories WHERE id = ?", (memory_id,)).fetchone()
            if folded_row is not None:
                self._purge(memory_id, int(folded_row["rowid"]), preserve_daemon_mirror=True)
            self.conn.execute("DELETE FROM engine_meta WHERE key = ?", (f"memory_alias:{memory_id}",))
        audit_event(
            self.conn,
            action="memory.forget",
            project_id=project_id,
            subject_id=canonical_id,
            labels=["local hard delete", "vault purged", "history purged", "vectors purged"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "memoryID": canonical_id,
            "projectID": project_id,
            "purged": ["memory", "vector", "history", "relations", "vault"],
        }

    def _purge(self, memory_id: str, rowid: int, *, preserve_daemon_mirror: bool = False) -> None:
        # A hard forget is this device's decision, and blind sync must not undo
        # it: record the receipt before the row is gone, keyed both by id and by
        # the `(project_id, scope, body_hash)` identity a remote copy converges
        # on, so the same fact cannot come back under another engine's id.
        self._record_forget_receipt(memory_id)
        self.conn.execute("DELETE FROM memory_vectors WHERE memory_rowid = ?", (rowid,))
        self.conn.execute("DELETE FROM memory_history WHERE memory_id = ?", (memory_id,))
        self.conn.execute("DELETE FROM memory_relations WHERE memory_id = ?", (memory_id,))
        self.conn.execute("DELETE FROM memory_vault WHERE memory_id = ?", (memory_id,))
        if not preserve_daemon_mirror:
            self.conn.execute("DELETE FROM engine_meta WHERE key = ?", (f"daemon_mirror:{memory_id}",))
        # A replay receipt that points at this memory must not claim it still exists.
        self.conn.execute("DELETE FROM memory_ingest WHERE decisions_json LIKE ?", (f'%"memoryID":"{memory_id}"%',))
        self.conn.execute("UPDATE memories SET superseded_by = NULL WHERE superseded_by = ?", (memory_id,))
        # A foreign engine id that folded into this row now points at nothing, and
        # neither the row's applied-remote mark nor the convergence ledger entries
        # that key a body to it can outlive the row they describe.
        self.conn.execute(
            "DELETE FROM engine_meta WHERE key LIKE 'memory_alias:%' AND value = ?",
            (memory_id,),
        )
        self.conn.execute("DELETE FROM engine_meta WHERE key = ?", (f"sync_mark:{memory_id}",))
        self.conn.execute(
            "DELETE FROM engine_meta WHERE key LIKE 'sync_identity:%' AND value = ?",
            (memory_id,),
        )
        self.conn.execute("DELETE FROM memories WHERE id = ?", (memory_id,))

    def forget_all(
        self,
        *,
        project_path: str | None,
        scope: str | None = None,
        kinds: Sequence[str] | None = None,
        confirm: str = "",
        selection_token: str | None = None,
    ) -> dict[str, Any]:
        """Two-step bulk delete. The preview returns `selectionToken`, a digest
        of the exact rows it would delete; the confirmation must carry that
        token, so rows created or filters changed between the two calls are
        refused instead of silently deleted."""
        project_id, root = resolve_project(self.conn, project_path)
        # T5, in SQL because the selection token digests exactly the ids this
        # query returns: a team row excluded here is excluded from the preview,
        # from the token and from the delete, all three in agreement.
        where = ["project_id = ?", f"json_extract(metadata_json, '{TEAM_ID_JSON_PATH}') IS NULL"]
        params: list[Any] = [project_id]
        normalized: list[str] = []
        if scope and scope != "all":
            where.append("scope = ?")
            params.append(scope)
        if kinds:
            try:
                normalized = sorted({normalize_kind_strict(k) for k in kinds})
            except ValueError as exc:
                return {
                    "status": "rejected",
                    "code": "INVALID_KIND",
                    "reason": str(exc),
                    "allowed": list(KINDS),
                    **project_payload(project_id, root),
                }
            where.append(f"kind IN ({','.join('?' * len(normalized))})")
            params.extend(normalized)
        rows = self.conn.execute(f"SELECT rowid, id FROM memories WHERE {' AND '.join(where)}", params).fetchall()  # noqa: S608 — fixed column names, bound values
        memory_ids = sorted(str(row["id"]) for row in rows)
        current_token = sha256_hex(
            _json_dumps({"project": project_id, "scope": scope or "all", "kinds": normalized, "ids": memory_ids})
        )[:24]
        if confirm != "DELETE" or (selection_token or "") != current_token:
            code = None
            if confirm == "DELETE":
                code = "SELECTION_TOKEN_REQUIRED" if not selection_token else "SELECTION_CHANGED"
            return {
                "status": "confirm_required",
                **({"code": code} if code else {}),
                "wouldDelete": len(rows),
                "confirm": "DELETE",
                "selectionToken": current_token,
                **project_payload(project_id, root),
            }
        for row in rows:
            # Keep each daemon id as a tombstone until the server confirms the
            # corresponding remote deletion.
            self._purge(str(row["id"]), int(row["rowid"]), preserve_daemon_mirror=True)
        audit_event(
            self.conn,
            action="memory.forget_all",
            project_id=project_id,
            subject_id=None,
            labels=[f"deleted:{len(rows)}", f"scope:{scope or 'all'}"],
            actor=self.config.actor,
        )
        self._commit()
        self._invalidate_cache()
        return {
            "status": "ok",
            "deleted": len(rows),
            "deletedMemoryIDs": memory_ids,
            **project_payload(project_id, root),
        }
