"""Settings endpoints with encrypted API key storage."""

import uuid

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from ..core.crypto import decrypt_or_empty, encrypt, mask_key
from ..core.database import get_db
from ..core.models import AppSettingsModel
from ..core.schemas import (
    AppearanceSettings,
    AppSettingsOut,
    AppSettingsUpdate,
    ChatDefaults,
    MinerUSettings,
    ModelProfileOut,
    ProfileAssignment,
    TestConnectionResult,
)
from ..services.llm import LLMClient
from ..services.mineru import GRADIO_FN

router = APIRouter()

DEFAULT_SETTINGS = {
    "model_profiles": [],
    "profile_assignment": {
        "translation_and_extraction": "",
        "logic_chain_and_summary": "",
        "figure_vision": "",
        "chat": "",
        "note_synthesis": "",
    },
    "mineru": {
        "mode": "cloud",
        "base_url": "https://mineru.net/api/v4",
        "local_url": "http://127.0.0.1:7860",
        "api_key": "",
        "default_options": {
            "is_ocr": True,
            "enable_formula": True,
            "enable_table": True,
            "model_backend": "pipeline",
        },
    },
    "appearance": {
        "accent_color": "#2F6FED",
        "theme_mode": "system",
        "reading_font_size": 18,
        "bilingual_layout": "stacked",
    },
    "chat_defaults": {
        "preset_prompts": [
            {"label": "总结全文", "template": "请用200-300字总结这篇论文的核心内容，包括问题、方法、结果和结论。"},
            {"label": "总结方法", "template": "请详细总结本文使用的核心方法/技术手段及其创新点。"},
            {"label": "亮点与创新点", "template": "请列出本文的主要创新点和亮点贡献。"},
            {"label": "局限与未来方向", "template": "请分析本文的局限性以及可能的未来研究方向。"},
            {"label": "提取实验设置", "template": "请提取本文的实验设置，包括数据集、评价指标、基线方法和关键超参数。"},
            {"label": "生成自测思考题", "template": "请基于本文内容生成5道思考题，帮助我检验对论文的理解程度。"},
        ],
        "target_language": "zh-CN",
        "enable_wikilinks": True,
    },
}


async def _get_or_create(db: AsyncSession) -> dict:
    row = await db.get(AppSettingsModel, "singleton")
    if not row:
        row = AppSettingsModel(id="singleton", data=DEFAULT_SETTINGS)
        db.add(row)
        await db.commit()
        await db.refresh(row)
    return row


@router.get("")
async def get_settings(db: AsyncSession = Depends(get_db)) -> AppSettingsOut:
    row = await _get_or_create(db)
    data = row.data

    profiles = []
    for p in data.get("model_profiles", []):
        plain_key = decrypt_or_empty(p.get("api_key", ""))
        profiles.append(ModelProfileOut(
            id=p["id"], name=p["name"], base_url=p["base_url"],
            api_key_masked=mask_key(plain_key) if plain_key else "",
            api_key_configured=bool(plain_key),
            model=p["model"],
            temperature=p.get("temperature"), max_tokens=p.get("max_tokens"),
            reasoning_effort=p.get("reasoning_effort"), streaming=p.get("streaming", True),
        ))

    mineru_data = data.get("mineru", DEFAULT_SETTINGS["mineru"])
    mineru_plain_key = decrypt_or_empty(mineru_data.get("api_key", ""))

    return AppSettingsOut(
        model_profiles=profiles,
        profile_assignment=ProfileAssignment(**data.get("profile_assignment", DEFAULT_SETTINGS["profile_assignment"])),
        mineru=MinerUSettings(
            **{k: v for k, v in mineru_data.items()
               if k not in ("api_key", "api_key_configured")},
            api_key=mask_key(mineru_plain_key) if mineru_plain_key else "",
            api_key_configured=bool(mineru_plain_key),
        ),
        appearance=AppearanceSettings(**data.get("appearance", DEFAULT_SETTINGS["appearance"])),
        chat_defaults=ChatDefaults(**data.get("chat_defaults", DEFAULT_SETTINGS["chat_defaults"])),
    )


@router.put("")
async def update_settings(update: AppSettingsUpdate, db: AsyncSession = Depends(get_db)) -> AppSettingsOut:
    row = await _get_or_create(db)
    data = dict(row.data)

    if update.model_profiles is not None:
        existing_profiles = {
            p.get("id"): p for p in data.get("model_profiles", []) if p.get("id")
        }
        profiles = []
        for p in update.model_profiles:
            pid = p.id or uuid.uuid4().hex[:8]
            clean_key = p.api_key.strip()
            if clean_key and not clean_key.startswith("*"):
                encrypted_key = encrypt(clean_key)
            else:
                encrypted_key = existing_profiles.get(pid, {}).get("api_key", "")
            profiles.append({
                "id": pid, "name": p.name.strip(), "base_url": LLMClient._normalize_base_url(p.base_url),
                "api_key": encrypted_key, "model": p.model.strip(),
                "temperature": p.temperature, "max_tokens": p.max_tokens,
                "reasoning_effort": p.reasoning_effort,
                "reasoning_budget_tokens": p.reasoning_budget_tokens,
                "extra_params_json": p.extra_params_json,
                "streaming": p.streaming,
            })
        data["model_profiles"] = profiles

    if update.profile_assignment is not None:
        data["profile_assignment"] = update.profile_assignment.model_dump()

    if update.mineru is not None:
        mineru_data = update.mineru.model_dump()
        mineru_data.pop("api_key_configured", None)
        if mineru_data.get("api_key") and not mineru_data["api_key"].startswith("*"):
            mineru_data["api_key"] = encrypt(mineru_data["api_key"])
        else:
            existing = data.get("mineru", {}).get("api_key", "")
            mineru_data["api_key"] = existing
        data["mineru"] = mineru_data

    if update.appearance is not None:
        data["appearance"] = update.appearance.model_dump()

    if update.chat_defaults is not None:
        data["chat_defaults"] = update.chat_defaults.model_dump()

    row.data = data
    await db.commit()

    return await get_settings(db)


REASONING_LEVELS = ["off", "low", "medium", "high"]


async def _probe_model_output_limit(base_url: str, api_key: str, model: str) -> int | None:
    """Best-effort: read /models metadata for an explicit output-token limit."""
    import httpx

    headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{base_url.rstrip('/')}/models", headers=headers)
            if not resp.is_success:
                return None
            payload = resp.json()
    except Exception:
        return None
    entries = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(entries, list):
        return None
    entry = next((e for e in entries if isinstance(e, dict) and e.get("id") == model), None)
    if entry is None:
        return None
    # OpenRouter nests the limit under top_provider; vLLM/LiteLLM expose it flat.
    nested = entry.get("top_provider") if isinstance(entry.get("top_provider"), dict) else {}
    for source in (nested, entry):
        for key in ("max_completion_tokens", "max_output_tokens", "max_tokens"):
            value = source.get(key)
            if isinstance(value, int) and 0 < value <= 1_000_000:
                return value
    return None


async def _probe_chat_capability(base_url: str, api_key: str, model: str) -> tuple[bool, bool, str]:
    """Tiny completion without/with reasoning_effort.

    The baseline request (no reasoning_effort) establishes connectivity; the
    follow-up with ``reasoning_effort: "low"`` detects whether the model accepts
    it. Returns (success, supports_reasoning, error_message).
    """
    import httpx

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    url = f"{base_url.rstrip('/')}/chat/completions"
    messages = [{"role": "user", "content": "Reply with the single word: OK"}]

    async with httpx.AsyncClient(timeout=30) as client:
        payload = {"model": model, "messages": messages, "max_tokens": 128}
        successful_payload = payload
        resp = await client.post(url, headers=headers, json=payload)
        if not resp.is_success:
            error = str(LLMClient._error_from_response(resp))
            # Newer OpenAI models only accept max_completion_tokens.
            if resp.status_code == 400 and "max_completion_tokens" in error.lower():
                retry = {"model": model, "messages": messages, "max_completion_tokens": 128}
                resp = await client.post(url, headers=headers, json=retry)
                if not resp.is_success:
                    return False, False, str(LLMClient._error_from_response(resp))
                successful_payload = retry
            else:
                return False, False, error

        reasoning_payload = dict(successful_payload)
        reasoning_payload["reasoning_effort"] = "low"
        reasoning_resp = await client.post(url, headers=headers, json=reasoning_payload)
        return True, reasoning_resp.is_success, ""


@router.post("/test-llm", response_model=TestConnectionResult)
async def test_llm_connection(body: dict, db: AsyncSession = Depends(get_db)):
    base_url = LLMClient._normalize_base_url(str(body.get("base_url", "")))
    model = str(body.get("model", "")).strip()
    if not base_url:
        return TestConnectionResult(success=False, message="请先填写 Base URL")
    if not model:
        return TestConnectionResult(success=False, message="请先填写模型名称")
    api_key = str(body.get("api_key", "")).strip()
    profile_id = body.get("profile_id", "")
    if not api_key:
        row = await _get_or_create(db)
        profiles = row.data.get("model_profiles", [])
        profile = next((p for p in profiles if p.get("id") == profile_id), None)
        if profile is None and len(profiles) == 1:
            profile = profiles[0]
        if profile:
            api_key = decrypt_or_empty(profile.get("api_key", ""))
    if not api_key:
        return TestConnectionResult(success=False, message="请先填写 API Key,或先保存过可用密钥")

    try:
        success, supports_reasoning, error = await _probe_chat_capability(base_url, api_key, model)
    except Exception as e:
        return TestConnectionResult(success=False, message=f"连接失败: {str(e)[:200]}")
    if not success:
        return TestConnectionResult(success=False, message=f"连接失败: {error}")

    output_limit = await _probe_model_output_limit(base_url, api_key, model)
    message = "连接成功,该模型支持思考强度调节" if supports_reasoning else "连接成功,该模型不支持思考强度(将保持关闭)"
    if output_limit:
        message += f",默认单次最大输出 {output_limit}"
    return TestConnectionResult(
        success=True,
        message=message + "。",
        supports_reasoning=supports_reasoning,
        reasoning_levels=list(REASONING_LEVELS) if supports_reasoning else ["off"],
        default_max_output_tokens=output_limit,
    )


@router.post("/test-mineru", response_model=TestConnectionResult)
async def test_mineru_connection(body: dict, db: AsyncSession = Depends(get_db)):
    import httpx
    mode = str(body.get("mode", "cloud"))
    base_url = body.get("base_url", "")
    api_key = body.get("api_key", "")

    if mode == "local":
        local_url = str(body.get("local_url", "")).strip() or "http://127.0.0.1:7860"
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.get(f"{local_url.rstrip('/')}/gradio_api/info")
                resp.raise_for_status()
                info = resp.json()
                endpoints = info.get("named_endpoints", {})
                if f"/{GRADIO_FN}" in endpoints:
                    return TestConnectionResult(success=True, message="本地 MinerU 服务连接成功")
                return TestConnectionResult(success=False, message="服务已响应，但不是 MinerU Gradio 接口")
        except Exception as e:
            return TestConnectionResult(success=False, message=f"本地 MinerU 连接失败: {str(e)[:200]}")

    if not api_key:
        row = await _get_or_create(db)
        api_key = decrypt_or_empty(row.data.get("mineru", {}).get("api_key", ""))
    url = base_url or "https://mineru.net/api/v4"
    try:
        if not api_key:
            return TestConnectionResult(success=False, message="尚未保存可用的 MinerU Token")
        headers = {"Authorization": f"Bearer {api_key}"}
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(f"{url.rstrip('/')}/extract/task/__paperico_connection_test__", headers=headers)
            if resp.status_code in (401, 403):
                return TestConnectionResult(success=False, message=f"认证失败 (HTTP {resp.status_code})，请检查 Token")
            payload = resp.json() if "json" in resp.headers.get("content-type", "") else {}
            code = str(payload.get("code", ""))
            if code in ("A0202", "A0211"):
                return TestConnectionResult(success=False, message=f"认证失败 ({code})，请检查或更新 Token")
            if resp.status_code < 500:
                return TestConnectionResult(success=True, message="MinerU Token 有效，服务连接成功")
            return TestConnectionResult(success=False, message=f"MinerU 服务异常 (HTTP {resp.status_code})")
    except Exception as e:
        return TestConnectionResult(success=False, message=f"连接失败: {str(e)[:200]}")
