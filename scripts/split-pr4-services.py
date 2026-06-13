#!/usr/bin/env python3
"""Split monolithic SearchService + ConversationStore for PR4."""
from __future__ import annotations

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def split_search() -> None:
    root = REPO / "AgentLens/Services/SearchService.swift"
    lines = root.read_text().splitlines(keepends=True)

    def slice_range(start: int, end: int) -> str:
        # 1-based inclusive line numbers
        return "".join(lines[start - 1 : end])

    header = slice_range(1, 75)
    factory_body = slice_range(76, 316)
    query_api = slice_range(318, 421)
    retrieval_body = slice_range(422, 931)
    health_body = slice_range(933, 1099)
    ranking_body = slice_range(1101, 1290)
    trailing = slice_range(1293, len(lines))

    main_path = REPO / "AgentLens/Services/Search/SearchService.swift"
    main_path.write_text(
        header
        + query_api
        + "\n}\n",
        encoding="utf-8",
    )

    def write_extension(name: str, body: str, *, suffix: str = "") -> None:
        path = REPO / f"AgentLens/Services/Search/SearchService+{name}.swift"
        text = (
            "import Foundation\n"
            "import OpenBurnBarCore\n\n"
            "extension SearchService {\n"
            + _indent_extension_body(body)
            + "}\n"
            + suffix
        )
        path.write_text(text, encoding="utf-8")

    write_extension("Factory", factory_body)
    write_extension("Retrieval", retrieval_body)
    write_extension("Health", health_body)
    write_extension("Ranking", ranking_body, suffix="\n" + trailing)


def _indent_extension_body(body: str) -> str:
    stripped = body.strip("\n")
    if not stripped:
        return ""
    out: list[str] = []
    for line in stripped.splitlines(keepends=True):
        if line.strip():
            out.append("    " + line)
        else:
            out.append(line)
    return "".join(out) + "\n"


def split_conversation_store() -> None:
    root = REPO / "AgentLens/Services/DataStore/ConversationStore.swift"
    lines = root.read_text().splitlines(keepends=True)

    def slice_range(start: int, end: int) -> str:
        return "".join(lines[start - 1 : end])

    facade = slice_range(1, 14) + slice_range(978, len(lines))
    crud = slice_range(15, 469)
    cloud = slice_range(471, 585)
    chat = slice_range(587, 780)
    fts = slice_range(782, 878)
    transcript = slice_range(880, 976)

    root.write_text(facade.rstrip() + "\n", encoding="utf-8")

    def write_ext(suffix: str, mark: str, body: str) -> None:
        path = REPO / f"AgentLens/Services/DataStore/ConversationStore+{suffix}.swift"
        text = (
            "import Foundation\n"
            "import GRDB\n"
            "import OpenBurnBarCore\n\n"
            f"// MARK: - ConversationStore {mark}\n\n"
            "extension ConversationStore {\n"
            + _indent_extension_body(body)
            + "}\n"
        )
        path.write_text(text, encoding="utf-8")

    write_ext("CRUD", "CRUD", crud)
    write_ext("CloudSync", "Cloud Sync", cloud)
    write_ext("Chat", "Chat", chat)
    write_ext("FTS", "FTS", fts)
    write_ext("TranscriptScan", "Transcript Scan", transcript)


def patch_projection_yield() -> None:
    jobs = REPO / "AgentLens/Services/ProjectionPipeline/ProjectionPipelineService+Jobs.swift"
    text = jobs.read_text(encoding="utf-8")
    needle = "                report.leasedJobs += 1\n\n            do {"
    insert = (
        "                report.leasedJobs += 1\n"
        "            if report.leasedJobs % ProjectionPipelineRuntimeTuning.sweepYieldInterval == 0 {\n"
        "                await Task.yield()\n"
        "            }\n\n            do {"
    )
    if needle in text and insert not in text:
        jobs.write_text(text.replace(needle, insert, 1), encoding="utf-8")


def main() -> None:
    split_search()
    split_conversation_store()
    patch_projection_yield()
    print("split-pr4-services: done")


if __name__ == "__main__":
    main()
