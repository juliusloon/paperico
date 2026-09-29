"""SQLAlchemy ORM models matching the spec's data model."""

import uuid
from datetime import datetime, timezone
from sqlalchemy import (
    Column, String, Integer, Float, Text, Boolean, ForeignKey, JSON, Table, DateTime
)
from sqlalchemy.orm import relationship
from .database import Base


def _uuid() -> str:
    return uuid.uuid4().hex[:12]


def _now() -> str:
    """RFC3339 UTC timestamp, always 24 chars wide (milliseconds + Z).

    SQLite sorts these columns as plain strings, so every value must have the
    exact same width or same-second ordering can drift. See T0.2 in
    docs/agentero-execution-plan.md.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


# Many-to-many: Block <-> MethodEntity
block_entity_table = Table(
    "block_entity",
    Base.metadata,
    Column("block_id", String, ForeignKey("blocks.id"), primary_key=True),
    Column("entity_id", String, ForeignKey("method_entities.id"), primary_key=True),
)

# Many-to-many: Note <-> ChatMessage
note_message_table = Table(
    "note_message",
    Base.metadata,
    Column("note_id", String, ForeignKey("notes.id"), primary_key=True),
    Column("message_id", String, ForeignKey("chat_messages.id"), primary_key=True),
)


class ProjectGroup(Base):
    __tablename__ = "project_groups"

    id = Column(String, primary_key=True, default=_uuid)
    name = Column(String, nullable=False)
    description = Column(String, default="")
    color_tag = Column(String, default="")
    created_at = Column(String, default=_now)

    papers = relationship("Paper", back_populates="project", lazy="selectin")


class Paper(Base):
    __tablename__ = "papers"

    id = Column(String, primary_key=True, default=_uuid)
    project_id = Column(String, ForeignKey("project_groups.id"), nullable=True)
    title = Column(String, default="")
    title_zh = Column(String, default="")
    authors = Column(JSON, default=list)
    year = Column(Integer, nullable=True)
    venue = Column(String, default="")
    source_type = Column(String, default="pdf_upload")  # pdf_upload | url_pdf | url_html
    source_url = Column(String, default="")
    original_file_name = Column(String, default="")
    domain_tags = Column(JSON, default=list)
    tldr = Column(String, default="")
    narrative_summary = Column(Text, default="")
    contributions = Column(JSON, default=list)
    difficulty_estimate = Column(String, default="")
    status = Column(String, default="uploaded")
    error_message = Column(String, default="")
    error_code = Column(String, nullable=True)
    file_sha256 = Column(String, nullable=True)  # upload dedup key (T1.4)
    reading_progress = Column(Float, default=0.0)
    mineru_task_id = Column(String, default="")
    created_at = Column(String, default=_now)
    updated_at = Column(String, default=_now)
    last_opened_at = Column(String, nullable=True)
    pdf_path = Column(String, default="")
    mineru_output_dir = Column(String, default="")

    project = relationship("ProjectGroup", back_populates="papers", lazy="selectin")
    blocks = relationship("Block", back_populates="paper", order_by="Block.order", lazy="selectin")
    entities = relationship("MethodEntity", back_populates="paper", lazy="selectin")
    chat_sessions = relationship("ChatSession", back_populates="paper", lazy="selectin")
    notes = relationship("Note", back_populates="paper", lazy="selectin")


class Block(Base):
    __tablename__ = "blocks"

    id = Column(String, primary_key=True, default=_uuid)
    paper_id = Column(String, ForeignKey("papers.id"), nullable=False)
    order = Column(Integer, nullable=False)
    kind = Column(String, default="paragraph")  # section_heading|paragraph|list_item|figure|table|equation
    page_idx = Column(Integer, nullable=True)
    bbox = Column(JSON, nullable=True)
    section_title = Column(String, default="")
    # Text fields
    text_original = Column(Text, default="")
    text_zh = Column(Text, default="")
    one_liner = Column(String, default="")
    keywords = Column(JSON, default=list)
    role_in_narrative = Column(String, default="")
    # Figure/table fields
    image_path = Column(String, default="")
    caption_original = Column(Text, default="")
    caption_zh = Column(Text, default="")
    figure_type = Column(String, default="")
    core_takeaways = Column(JSON, default=list)
    data_reading_notes = Column(Text, default="")
    table_html = Column(Text, default="")
    # Equation fields
    latex = Column(Text, default="")
    plain_explanation = Column(Text, default="")

    paper = relationship("Paper", back_populates="blocks")
    entities = relationship("MethodEntity", secondary=block_entity_table, back_populates="blocks", lazy="selectin")


class MethodEntity(Base):
    __tablename__ = "method_entities"

    id = Column(String, primary_key=True, default=_uuid)
    paper_id = Column(String, ForeignKey("papers.id"), nullable=False)
    canonical_key = Column(String, nullable=False)
    name = Column(String, nullable=False)
    category = Column(String, default="OTHER")
    definition_zh = Column(Text, default="")
    block_refs = Column(JSON, default=list)

    paper = relationship("Paper", back_populates="entities")
    blocks = relationship("Block", secondary=block_entity_table, back_populates="entities")


class ChatSession(Base):
    __tablename__ = "chat_sessions"

    id = Column(String, primary_key=True, default=_uuid)
    paper_id = Column(String, ForeignKey("papers.id"), nullable=False)
    title = Column(String, default="")
    created_at = Column(String, default=_now)

    paper = relationship("Paper", back_populates="chat_sessions")
    messages = relationship("ChatMessage", back_populates="session", order_by="ChatMessage.created_at", lazy="selectin")


class ChatMessage(Base):
    __tablename__ = "chat_messages"

    id = Column(String, primary_key=True, default=_uuid)
    session_id = Column(String, ForeignKey("chat_sessions.id"), nullable=False)
    role = Column(String, nullable=False)  # user | assistant
    content = Column(Text, default="")
    attached_context = Column(JSON, nullable=True)
    cited_block_ids = Column(JSON, nullable=True)
    created_at = Column(String, default=_now)

    session = relationship("ChatSession", back_populates="messages")


class Note(Base):
    __tablename__ = "notes"

    id = Column(String, primary_key=True, default=_uuid)
    paper_id = Column(String, ForeignKey("papers.id"), nullable=False)
    title = Column(String, default="")
    markdown_content = Column(Text, default="")
    created_at = Column(String, default=_now)
    updated_at = Column(String, default=_now)

    paper = relationship("Paper", back_populates="notes")
    source_messages = relationship("ChatMessage", secondary=note_message_table, lazy="selectin")


class AppSettingsModel(Base):
    """Singleton row storing the entire app settings as JSON."""
    __tablename__ = "app_settings"

    id = Column(String, primary_key=True, default=lambda: "singleton")
    data = Column(JSON, default=dict)
    updated_at = Column(String, default=_now)
