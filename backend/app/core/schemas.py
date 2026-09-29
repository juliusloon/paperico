"""Pydantic schemas for API request/response validation."""

from __future__ import annotations
from pydantic import BaseModel, Field
from typing import Optional


# ── Projects ──────────────────────────────────────────────

class ProjectCreate(BaseModel):
    name: str
    description: str = ""
    color_tag: str = ""


class ProjectOut(BaseModel):
    id: str
    name: str
    description: str
    color_tag: str
    paper_count: int = 0
    created_at: str

    class Config:
        from_attributes = True


# ── Papers ────────────────────────────────────────────────

class PaperCreate(BaseModel):
    project_id: Optional[str] = None
    source_url: Optional[str] = None


class PaperMoveRequest(BaseModel):
    paper_ids: list[str] = Field(min_length=1, max_length=500)
    project_id: Optional[str] = None


class PaperRenameRequest(BaseModel):
    title: str = Field(min_length=1, max_length=500)


class PaperListItem(BaseModel):
    id: str
    title: str
    title_zh: str
    authors: list[str]
    year: Optional[int]
    domain_tags: list[str]
    status: str
    project_id: Optional[str]
    source_type: str
    original_file_name: str
    created_at: str
    last_opened_at: Optional[str]
    tldr: str = ""
    narrative_summary: str = ""
    contributions: list[str] = []
    difficulty_estimate: str = ""
    venue: str = ""
    error_message: str = ""
    error_code: str = ""

    class Config:
        from_attributes = True


class BlockOut(BaseModel):
    id: str
    order: int
    kind: str
    page_idx: Optional[int]
    # MinerU page-relative bbox, both axes normalized to 0–1000 (T2.3).
    bbox: Optional[list[float]] = None
    section_title: str
    text_original: str
    text_zh: str
    one_liner: str
    keywords: list[str]
    role_in_narrative: str
    image_path: str
    caption_original: str
    caption_zh: str
    figure_type: str
    core_takeaways: list[str]
    data_reading_notes: str
    table_html: str
    latex: str
    plain_explanation: str
    entity_refs: list[str] = []

    class Config:
        from_attributes = True


class EntityOut(BaseModel):
    id: str
    canonical_key: str
    name: str
    category: str
    definition_zh: str
    block_refs: list[str]

    class Config:
        from_attributes = True


class PaperDetail(BaseModel):
    paper: PaperListItem
    blocks: list[BlockOut]
    entities: list[EntityOut]


class PaperStatusOut(BaseModel):
    id: str
    status: str
    error_message: str
    error_code: str = ""


# ── Chat ──────────────────────────────────────────────────

class AttachedContext(BaseModel):
    type: str  # text_selection | method_card | figure | preset_prompt
    ref_block_id: Optional[str] = None
    ref_entity_id: Optional[str] = None
    snippet: Optional[str] = None


class ChatMessageCreate(BaseModel):
    content: str
    session_id: Optional[str] = None
    attached_context: list[AttachedContext] = []


class ChatMessageOut(BaseModel):
    id: str
    session_id: str
    role: str
    content: str
    attached_context: Optional[list[dict]]
    cited_block_ids: Optional[list[str]]
    created_at: str

    class Config:
        from_attributes = True


class ChatSessionOut(BaseModel):
    id: str
    paper_id: str
    title: str
    messages: list[ChatMessageOut]
    created_at: str

    class Config:
        from_attributes = True


# ── Notes ─────────────────────────────────────────────────

class NoteCreate(BaseModel):
    title: str = ""
    message_ids: list[str] = []


class NoteOut(BaseModel):
    id: str
    paper_id: str
    title: str
    markdown_content: str
    created_at: str
    updated_at: str

    class Config:
        from_attributes = True


# ── Settings ──────────────────────────────────────────────

class ModelProfileOut(BaseModel):
    id: str
    name: str
    base_url: str
    api_key_masked: str
    api_key_configured: bool = False
    model: str
    temperature: Optional[float]
    max_tokens: Optional[int]
    reasoning_effort: Optional[str]
    streaming: bool


class ModelProfileCreate(BaseModel):
    id: Optional[str] = None
    name: str
    base_url: str
    api_key: str = ""
    model: str
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    reasoning_effort: Optional[str] = None
    reasoning_budget_tokens: Optional[int] = None
    extra_params_json: Optional[str] = None
    streaming: bool = True


class MinerUSettings(BaseModel):
    mode: str = "cloud"
    base_url: str = "https://mineru.net/api/v4"
    local_url: str = "http://127.0.0.1:7860"
    api_key: str = ""
    api_key_configured: bool = False
    default_options: dict = {}


class AppearanceSettings(BaseModel):
    accent_color: str = "#2F6FED"
    theme_mode: str = "system"
    reading_font_size: int = 18
    bilingual_layout: str = "stacked"


class ChatDefaults(BaseModel):
    preset_prompts: list[dict] = []
    target_language: str = "zh-CN"
    enable_wikilinks: bool = True


class ProfileAssignment(BaseModel):
    translation_and_extraction: str = ""
    logic_chain_and_summary: str = ""
    figure_vision: str = ""
    chat: str = ""
    note_synthesis: str = ""


class AppSettingsOut(BaseModel):
    model_profiles: list[ModelProfileOut]
    profile_assignment: ProfileAssignment
    mineru: MinerUSettings
    appearance: AppearanceSettings
    chat_defaults: ChatDefaults


class AppSettingsUpdate(BaseModel):
    model_profiles: Optional[list[ModelProfileCreate]] = None
    profile_assignment: Optional[ProfileAssignment] = None
    mineru: Optional[MinerUSettings] = None
    appearance: Optional[AppearanceSettings] = None
    chat_defaults: Optional[ChatDefaults] = None


class TestConnectionResult(BaseModel):
    success: bool
    message: str


# ── Library ───────────────────────────────────────────────

class MethodIndexItem(BaseModel):
    canonical_key: str
    name: str
    category: str
    definition_zh: str
    papers: list[dict]  # [{paper_id, title, block_ids}]
