from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_functional_qa_artifacts_are_published_only_after_final_redaction():
    workflow = (ROOT / ".github/workflows/qa.yml").read_text(encoding="utf-8")

    assert "id: qa_artifacts" in workflow
    assert "node scripts/ci/redact-qa-artifacts.mjs qa-results" in workflow
    assert "rm -rf qa-results" in workflow
    assert "QA_ARTIFACTS_READY: ${{ steps.qa_artifacts.outputs.ready }}" in workflow

    upload_index = workflow.index("- name: Upload QA artifacts")
    comment_index = workflow.index("- name: Post QA report as PR comment")
    conclusion_index = workflow.index("- name: Honest conclusion")

    assert "if: always() && steps.qa_artifacts.outputs.ready == 'true'" in workflow[
        upload_index:comment_index
    ]
    assert (
        "if: always() && steps.qa_artifacts.outputs.ready == 'true' "
        "&& steps.pr.outputs.number != ''"
    ) in workflow[comment_index:conclusion_index]
