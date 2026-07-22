import json

from select_wand_models import _public_payload, _public_payload_json


def test_public_payload_json_excludes_sensitive_candidate_fields() -> None:
    payload = {
        "status": "ok",
        "requestedCount": 1,
        "reason": "provider quota reset",
        "selected": [
            {
                "arg": "custom:Open-Code-Go-High-Reasoning:-Kimi-K2.6-0",
                "model": "kimi-k2.6",
                "displayName": "Open Code Go High Reasoning: Kimi K2.6",
                "provider": "opencode",
                "source": "factory.customModels",
                "api_key": "sk-sensitive",
                "token": "ghp_sensitive",
            }
        ],
    }

    public_payload = _public_payload(payload, sibling_index=0)
    encoded = _public_payload_json(public_payload)

    assert "sk-sensitive" not in encoded
    assert "ghp_sensitive" not in encoded
    decoded = json.loads(encoded)
    assert decoded == {
        "reason": "provider quota reset",
        "requestedCount": 1,
        "selectedCount": 1,
        "selectedForIndex": {
            "arg": "custom:Open-Code-Go-High-Reasoning:-Kimi-K2.6-0",
            "model": "kimi-k2.6",
            "displayName": "Open Code Go High Reasoning: Kimi K2.6",
            "provider": "opencode",
            "source": "factory.customModels",
        },
        "status": "ok",
    }


def test_public_payload_json_drops_secret_like_public_values() -> None:
    payload = {
        "status": "ok",
        "requestedCount": 1,
        "reason": "Authorization Bearer token leaked",
        "selected": [
            {
                "arg": "Authorization: Bearer abc",
                "model": "sk-secret-model",
                "displayName": "Token carrier",
                "provider": "opencode",
                "source": "factory.customModels",
            }
        ],
    }

    decoded = json.loads(_public_payload_json(_public_payload(payload, sibling_index=0)))

    assert decoded["reason"] is None
    assert decoded["selectedForIndex"] == {
        "provider": "opencode",
        "source": "factory.customModels",
    }


def test_partial_selection_does_not_wrap_missing_sibling_to_first_candidate() -> None:
    payload = {
        "status": "ok",
        "requestedCount": 2,
        "selectedCount": 1,
        "reason": "insufficient_proven_candidates",
        "selected": [{"arg": "proven-model", "provider": "openai"}],
    }

    first = _public_payload(payload, sibling_index=0)
    missing = _public_payload(payload, sibling_index=1)

    assert first["selectedForIndex"] is None
    assert missing["selectedForIndex"] is None


def test_complete_capped_selection_can_wrap_additional_siblings() -> None:
    payload = {
        "status": "ok",
        "requestedCount": 2,
        "selectedCount": 2,
        "reason": None,
        "selected": [
            {"arg": "model-a", "provider": "openai"},
            {"arg": "model-b", "provider": "anthropic"},
        ],
    }

    wrapped = _public_payload(payload, sibling_index=3)

    assert wrapped["selectedForIndex"] == {"arg": "model-b", "provider": "anthropic"}
