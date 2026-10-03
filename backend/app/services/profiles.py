"""Single implementation for resolving which LLM profile serves which role.

Implements agentero-lessons §2.2: the per-file resolver copies in
api/papers.py, api/chat.py and api/notes.py had drifted (chat/notes lacked the
"prefer a configured profile before env defaults" fix). All callers now go
through `resolve_llm`.
"""

from __future__ import annotations

from enum import StrEnum

from ..core.crypto import decrypt_or_empty
from .llm import LLMClient


class LlmRole(StrEnum):
    TRANSLATION_AND_EXTRACTION = "translation_and_extraction"
    LOGIC_CHAIN_AND_SUMMARY = "logic_chain_and_summary"
    FIGURE_VISION = "figure_vision"
    CHAT = "chat"
    NOTE_SYNTHESIS = "note_synthesis"


# Assignment keys each role may use, in fallback order. These mirror the `or`
# chains that used to live at the call sites (e.g. Reduce falls back to the
# translation profile for settings created before the separate Reduce slot).
_ROLE_CHAINS: dict[LlmRole, tuple[str, ...]] = {
    LlmRole.TRANSLATION_AND_EXTRACTION: ("translation_and_extraction",),
    LlmRole.LOGIC_CHAIN_AND_SUMMARY: ("logic_chain_and_summary", "translation_and_extraction"),
    LlmRole.FIGURE_VISION: ("figure_vision", "chat"),
    LlmRole.CHAT: ("chat", "translation_and_extraction"),
    LlmRole.NOTE_SYNTHESIS: ("note_synthesis", "chat"),
}


def _client_for(profile: dict) -> LLMClient:
    api_key = decrypt_or_empty(profile.get("api_key", ""))
    return LLMClient(
        base_url=profile.get("base_url", ""),
        api_key=api_key,
        model=profile.get("model", ""),
    )


def resolve_llm(app_settings: dict, role: LlmRole) -> LLMClient:
    """Resolve an LLM client for a role without silently losing a valid config.

    Semantics (the canonical ones, formerly duplicated three times):
    1. Walk the role's assignment fallback chain; the first non-empty key that
       matches a saved profile wins — even if that profile is unconfigured, so
       callers can surface a useful settings error via `client.is_configured`.
    2. Otherwise prefer the first fully configured profile: settings from older
       versions may carry blank assignments, and retranslate must not fail just
       because the separate Reduce slot was introduced later.
    3. A single saved profile is used even when unconfigured.
    4. Final fallback: the process-level default LLMClient() (env config).
    """
    profiles = app_settings.get("model_profiles", [])
    profiles = profiles if isinstance(profiles, list) else []
    assignment = app_settings.get("profile_assignment", {})
    assignment = assignment if isinstance(assignment, dict) else {}

    for key in _ROLE_CHAINS[role]:
        requested_id = str(assignment.get(key) or "").strip()
        if not requested_id:
            continue
        for profile in profiles:
            if isinstance(profile, dict) and str(profile.get("id", "")) == requested_id:
                return _client_for(profile)

    for profile in profiles:
        if not isinstance(profile, dict):
            continue
        client = _client_for(profile)
        if client.is_configured:
            return client

    if len(profiles) == 1 and isinstance(profiles[0], dict):
        return _client_for(profiles[0])

    return LLMClient()
