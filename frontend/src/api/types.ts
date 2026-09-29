/* ── Data types matching backend schemas ── */

export interface ProjectGroup {
  id: string;
  name: string;
  description: string;
  color_tag: string;
  paper_count: number;
  created_at: string;
}

export interface PaperListItem {
  id: string;
  title: string;
  title_zh: string;
  authors: string[];
  year: number | null;
  domain_tags: string[];
  status: string;
  project_id: string | null;
  source_type: string;
  original_file_name: string;
  created_at: string;
  last_opened_at: string | null;
  tldr: string;
  narrative_summary: string;
  contributions: string[];
  difficulty_estimate: string;
  venue: string;
  error_message: string;
  error_code?: string;
}

export interface Block {
  id: string;
  order: number;
  kind: string;
  page_idx: number | null;
  /** MinerU page-relative bbox [x0,y0,x1,y1], both axes normalized to 0–1000. */
  bbox: number[] | null;
  section_title: string;
  text_original: string;
  text_zh: string;
  one_liner: string;
  keywords: string[];
  role_in_narrative: string;
  image_path: string;
  caption_original: string;
  caption_zh: string;
  figure_type: string;
  core_takeaways: string[];
  data_reading_notes: string;
  table_html: string;
  latex: string;
  plain_explanation: string;
  entity_refs: string[];
}

export interface MethodEntity {
  id: string;
  canonical_key: string;
  name: string;
  category: string;
  definition_zh: string;
  block_refs: string[];
}

export interface PaperDetail {
  paper: PaperListItem;
  blocks: Block[];
  entities: MethodEntity[];
}

export interface AttachedContext {
  type: 'text_selection' | 'method_card' | 'figure' | 'preset_prompt';
  ref_block_id?: string;
  ref_entity_id?: string;
  snippet?: string;
}

export interface ChatMessage {
  id: string;
  session_id: string;
  role: 'user' | 'assistant';
  content: string;
  attached_context: AttachedContext[] | null;
  cited_block_ids: string[] | null;
  created_at: string;
}

export interface ChatSession {
  id: string;
  paper_id: string;
  title: string;
  messages: ChatMessage[];
  created_at: string;
}

export interface Note {
  id: string;
  paper_id: string;
  title: string;
  markdown_content: string;
  created_at: string;
  updated_at: string;
}

export interface ModelProfile {
  id: string;
  name: string;
  base_url: string;
  api_key_masked: string;
  api_key_configured: boolean;
  model: string;
  temperature: number | null;
  max_tokens: number | null;
  reasoning_effort: string | null;
  streaming: boolean;
}

export interface AppSettings {
  model_profiles: ModelProfile[];
  profile_assignment: {
    translation_and_extraction: string;
    logic_chain_and_summary: string;
    figure_vision: string;
    chat: string;
    note_synthesis: string;
  };
  mineru: {
    mode: string;
    base_url: string;
    local_url: string;
    api_key: string;
    api_key_configured: boolean;
    default_options: Record<string, unknown>;
  };
  appearance: {
    accent_color: string;
    theme_mode: string;
    reading_font_size: number;
    bilingual_layout: string;
  };
  chat_defaults: {
    preset_prompts: { label: string; template: string }[];
    target_language: string;
    enable_wikilinks: boolean;
  };
}

export interface MethodIndexItem {
  canonical_key: string;
  name: string;
  category: string;
  definition_zh: string;
  papers: { paper_id: string; title: string; block_ids: string[] }[];
}
