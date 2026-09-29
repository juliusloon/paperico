import { useEffect, useMemo, useState } from 'react';
import { Check, ChevronRight, Eye, EyeOff, Loader2, Palette, Save, ServerCog, ShieldCheck, TestTube2, X, Zap } from 'lucide-react';
import { api } from '../../api/client';
import { useAppStore, useSettingsStore } from '../../stores';

type SettingsTab = 'model' | 'parser' | 'appearance';
type Notice = { success: boolean; message: string } | null;

const DEFAULT_OPTIONS = { is_ocr: false, enable_formula: true, enable_table: true, language: 'en', model_backend: 'vlm' };

export default function SettingsPage() {
  const { settings, update } = useSettingsStore();
  const { setTheme, setAccentColor } = useAppStore();
  const [tab, setTab] = useState<SettingsTab>('model');
  const [saving, setSaving] = useState(false);
  const [testing, setTesting] = useState<'llm' | 'mineru' | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [showLlmKey, setShowLlmKey] = useState(false);
  const [showMineruKey, setShowMineruKey] = useState(false);
  const [llmForm, setLlmForm] = useState({ id: 'primary', name: '主要模型', base_url: 'https://api.openai.com/v1', api_key: '', model: 'gpt-4o-mini', temperature: 0.3, max_tokens: 8192, reasoning_effort: 'medium', streaming: true });
  const [mineruForm, setMineruForm] = useState({ mode: 'cloud', base_url: 'https://mineru.net/api/v4', local_url: 'http://127.0.0.1:7860', api_key: '', api_key_configured: false, default_options: DEFAULT_OPTIONS });
  const [appearance, setAppearance] = useState({ accent_color: '#275DCE', theme_mode: 'system', reading_font_size: 18, bilingual_layout: 'stacked' });

  useEffect(() => {
    if (!settings) return;
    setAppearance(settings.appearance);
    setMineruForm({ mode: settings.mineru.mode, base_url: settings.mineru.base_url, local_url: settings.mineru.local_url || 'http://127.0.0.1:7860', api_key: '', api_key_configured: settings.mineru.api_key_configured, default_options: { ...DEFAULT_OPTIONS, ...(settings.mineru.default_options as typeof DEFAULT_OPTIONS) } });
    const profile = settings.model_profiles[0];
    if (profile) setLlmForm((form) => ({ ...form, id: profile.id, name: profile.name, base_url: profile.base_url, model: profile.model, temperature: profile.temperature ?? .3, max_tokens: profile.max_tokens ?? 8192, reasoning_effort: profile.reasoning_effort || 'medium', streaming: profile.streaming, api_key: '' }));
  }, [settings]);

  const llmReady = Boolean(settings?.model_profiles[0]?.api_key_configured);
  const mineruIsLocal = mineruForm.mode === 'local';
  const mineruReady = mineruIsLocal ? Boolean(mineruForm.local_url.trim()) : Boolean(settings?.mineru.api_key_configured);
  const readyCount = Number(llmReady) + Number(mineruReady);
  const profileId = llmForm.id || 'primary';

  const runAction = async (action: () => Promise<void>) => {
    setSaving(true);
    try { await action(); } catch (error) { setNotice({ success: false, message: getMessage(error) }); } finally { setSaving(false); }
  };

  const modelProfile = () => ({
    ...llmForm,
    id: profileId,
    name: llmForm.name.trim() || '主要模型',
    base_url: llmForm.base_url.trim().replace(/\/+$/, '').replace(/\/chat\/completions$/, ''),
    api_key: llmForm.api_key.trim(),
    model: llmForm.model.trim(),
  });

  const saveLLM = () => runAction(async () => {
    const profile = modelProfile();
    await update({ model_profiles: [profile] as any, profile_assignment: { translation_and_extraction: profileId, logic_chain_and_summary: profileId, figure_vision: profileId, chat: profileId, note_synthesis: profileId } });
    setLlmForm((form) => ({ ...form, id: profileId, api_key: '' }));
    setNotice({ success: true, message: '模型配置已保存，并已分配给解析、总结、对话和笔记流程。' });
  });

  const saveMinerU = () => runAction(async () => {
    await update({ mineru: mineruForm as any });
    setMineruForm((form) => ({ ...form, api_key: '' }));
    setNotice({ success: true, message: 'MinerU 配置已保存。' });
  });

  const saveAppearance = () => runAction(async () => {
    await update({ appearance });
    setAccentColor(appearance.accent_color);
    setTheme(appearance.theme_mode as 'light' | 'dark' | 'system');
    setNotice({ success: true, message: '阅读外观已保存。' });
  });

  const testLLM = async () => {
    setTesting('llm'); setNotice(null);
    try {
      const profile = modelProfile();
      if (!profile.api_key && !llmReady) {
        setNotice({ success: false, message: '请先填写 API Key，再保存并测试。' });
        return;
      }
      await update({ model_profiles: [profile] as any, profile_assignment: { translation_and_extraction: profileId, logic_chain_and_summary: profileId, figure_vision: profileId, chat: profileId, note_synthesis: profileId } });
      const result = await api.settings.testLLM(profile.base_url, '', profile.model, profileId);
      setLlmForm((form) => ({ ...form, ...profile, api_key: '' }));
      setNotice(result);
    }
    catch (error) { setNotice({ success: false, message: getMessage(error) }); }
    finally { setTesting(null); }
  };

  const testMinerU = async () => {
    setTesting('mineru'); setNotice(null);
    try { setNotice(await api.settings.testMinerU({ mode: mineruForm.mode, base_url: mineruForm.base_url, local_url: mineruForm.local_url, api_key: mineruForm.api_key })); }
    catch (error) { setNotice({ success: false, message: getMessage(error) }); }
    finally { setTesting(null); }
  };

  const tabs = useMemo(() => [
    { id: 'model' as const, icon: Zap, label: 'AI 模型', description: '翻译、总结与问答' },
    { id: 'parser' as const, icon: ServerCog, label: 'PDF 解析', description: 'MinerU 云端或本地部署' },
    { id: 'appearance' as const, icon: Palette, label: '阅读外观', description: '主题、强调色与字号' },
  ], []);

  return (
    <main className="settings-page">
      <aside className="settings-sidebar">
        <nav>{tabs.map(({ id, icon: Icon, label, description }) => <button key={id} className={tab === id ? 'active' : ''} onClick={() => setTab(id)}><Icon size={15} /><span><strong>{label}</strong><small>{description}</small></span><ChevronRight size={13} /></button>)}</nav>
        <div className="readiness-card"><ShieldCheck size={17} /><span><strong>流程就绪度 {readyCount}/2</strong><small>{readyCount === 2 ? '可以上传并处理论文' : '需要补齐下方连接'}</small></span></div>
      </aside>

      <section className="settings-content">
        {tab === 'model' && (
          <SettingsSection kicker="MODEL CONNECTION" title="AI 模型连接" description="使用 OpenAI-compatible Chat Completions 接口。配置仅保存在本机数据库中，并使用稳定的本机密钥加密；一个配置会自动用于翻译、逻辑归纳、Chatbot 和笔记生成。" configured={llmReady}>
            <div className="settings-form-grid">
              <Field label="配置名称"><TextInput value={llmForm.name} onChange={(name) => setLlmForm({ ...llmForm, name })} /></Field>
              <Field label="模型名称" hint="必须与服务商控制台中的 model id 完全一致"><TextInput value={llmForm.model} onChange={(model) => setLlmForm({ ...llmForm, model })} placeholder="gpt-4o-mini" /></Field>
              <Field wide label="Base URL" hint="填写到 /v1，应用会自动追加 /chat/completions"><TextInput value={llmForm.base_url} onChange={(base_url) => setLlmForm({ ...llmForm, base_url })} placeholder="https://api.openai.com/v1" /></Field>
              <Field wide label="API Key" hint={llmReady ? `已保存：${settings?.model_profiles[0]?.api_key_masked}。留空会继续使用，不会覆盖。` : '测试时会先安全保存当前配置。'}><SecretInput visible={showLlmKey} onToggle={() => setShowLlmKey(!showLlmKey)} value={llmForm.api_key} onChange={(api_key) => setLlmForm({ ...llmForm, api_key })} placeholder={llmReady ? '留空以继续使用已保存密钥' : 'tp-...'} /></Field>
              <Field label="思考强度"><Select value={llmForm.reasoning_effort} onChange={(reasoning_effort) => setLlmForm({ ...llmForm, reasoning_effort })} options={[['off', '关闭'], ['low', '低'], ['medium', '中'], ['high', '高']]} /></Field>
              <Field label="单次最大输出"><NumberInput value={llmForm.max_tokens} onChange={(max_tokens) => setLlmForm({ ...llmForm, max_tokens })} /></Field>
            </div>
            <ActionRow saving={saving} testing={testing === 'llm'} onSave={saveLLM} onTest={testLLM} testLabel="保存并测试" />
          </SettingsSection>
        )}

        {tab === 'parser' && (
          <SettingsSection kicker="DOCUMENT PARSER" title="MinerU 精准解析" description={mineruIsLocal ? '调用本机部署的 MinerU Gradio 服务（如 Docker 版 mineru-gradio），无需 Token；MinerU.Chem 化学解析目前仅云端提供。' : 'MinerU Token 仅保存在本机数据库中，并使用稳定的本机密钥加密。本地 PDF 会申请官方签名上传地址，上传后自动轮询批任务。'} configured={mineruReady}>
            <div className="settings-form-grid">
              <Field wide label="解析方式"><Select value={mineruForm.mode} onChange={(mode) => setMineruForm({ ...mineruForm, mode })} options={[['cloud', 'MinerU 云端 API'], ['local', '本地部署（Gradio 服务）']]} /></Field>
              {mineruIsLocal ? (
                <Field wide label="本地服务地址" hint="指向 mineru-gradio 的 HTTP 地址，例如 http://127.0.0.1:7860"><TextInput value={mineruForm.local_url} onChange={(local_url) => setMineruForm({ ...mineruForm, local_url })} placeholder="http://127.0.0.1:7860" /></Field>
              ) : (
                <>
                  <Field wide label="Base URL"><TextInput value={mineruForm.base_url} onChange={(base_url) => setMineruForm({ ...mineruForm, base_url })} placeholder="https://mineru.net/api/v4" /></Field>
                  <Field wide label="MinerU Token" hint={settings?.mineru.api_key_configured ? `已保存：${settings?.mineru.api_key}。留空保存不会覆盖。` : '在 MinerU API 管理页面创建 Token。'}><SecretInput visible={showMineruKey} onToggle={() => setShowMineruKey(!showMineruKey)} value={mineruForm.api_key} onChange={(api_key) => setMineruForm({ ...mineruForm, api_key })} placeholder={settings?.mineru.api_key_configured ? '留空以继续使用已保存 Token' : 'Bearer Token（只填写 Token 本身）'} /></Field>
                </>
              )}
              <Field label="解析模型"><Select value={mineruForm.default_options.model_backend} onChange={(model_backend) => setMineruForm({ ...mineruForm, default_options: { ...mineruForm.default_options, model_backend } })} options={mineruIsLocal ? [['pipeline', 'Pipeline'], ['vlm', 'VLM Engine'], ['hybrid-engine', 'Hybrid Engine']] : [['vlm', 'VLM（推荐）'], ['pipeline', 'Pipeline']]}/></Field>
              <Field label="论文语言"><Select value={mineruForm.default_options.language} onChange={(language) => setMineruForm({ ...mineruForm, default_options: { ...mineruForm.default_options, language } })} options={[['en', '英文'], ['ch', '中文'], ['japan', '日文'], ['korean', '韩文']]}/></Field>
            </div>
            <div className="toggle-row"><Toggle label="公式识别" checked={mineruForm.default_options.enable_formula} onChange={(enable_formula) => setMineruForm({ ...mineruForm, default_options: { ...mineruForm.default_options, enable_formula } })} /><Toggle label="表格识别" checked={mineruForm.default_options.enable_table} onChange={(enable_table) => setMineruForm({ ...mineruForm, default_options: { ...mineruForm.default_options, enable_table } })} /><Toggle label="强制 OCR" checked={mineruForm.default_options.is_ocr} onChange={(is_ocr) => setMineruForm({ ...mineruForm, default_options: { ...mineruForm.default_options, is_ocr } })} /></div>
            <p className="settings-callout">你的示例是可检索文字型 PDF，建议关闭“强制 OCR”；公式和表格识别保持开启。</p>
            <ActionRow saving={saving} testing={testing === 'mineru'} onSave={saveMinerU} onTest={testMinerU} />
          </SettingsSection>
        )}

        {tab === 'appearance' && (
          <SettingsSection kicker="READING APPEARANCE" title="阅读外观" description="这些设置只影响界面，不会改变论文数据。" configured>
            <div className="settings-form-grid">
              <Field label="主题"><Select value={appearance.theme_mode} onChange={(theme_mode) => setAppearance({ ...appearance, theme_mode })} options={[['light', '亮色'], ['dark', '暗色'], ['system', '跟随系统']]} /></Field>
              <Field label="正文字号"><NumberInput value={appearance.reading_font_size} min={13} max={23} onChange={(reading_font_size) => setAppearance({ ...appearance, reading_font_size })} /></Field>
              <Field wide label="强调色"><div className="color-field"><input type="color" value={appearance.accent_color} onChange={(event) => setAppearance({ ...appearance, accent_color: event.target.value })} /><TextInput value={appearance.accent_color} onChange={(accent_color) => setAppearance({ ...appearance, accent_color })} /></div></Field>
            </div>
            <ActionRow saving={saving} onSave={saveAppearance} />
          </SettingsSection>
        )}
      </section>

      {notice && <div className={notice.success ? 'settings-notice success' : 'settings-notice error'}>{notice.success ? <Check size={14} /> : <X size={14} />}<span>{notice.message}</span><button onClick={() => setNotice(null)}><X size={11} /></button></div>}
    </main>
  );
}

function SettingsSection({ kicker, title, description, configured, children }: { kicker: string; title: string; description: string; configured: boolean; children: React.ReactNode }) {
  return <div className="settings-section"><header><div><span>{kicker}</span><h2>{title}</h2><p>{description}</p></div><em className={configured ? 'configured' : 'missing'}>{configured ? <><Check size={11} />已配置</> : <><X size={11} />需要配置</>}</em></header>{children}</div>;
}
function Field({ label, hint, wide, children }: { label: string; hint?: string; wide?: boolean; children: React.ReactNode }) { return <label className={wide ? 'settings-field wide' : 'settings-field'}><span>{label}</span>{children}{hint && <small>{hint}</small>}</label>; }
function TextInput({ value, onChange, placeholder = '' }: { value: string; onChange: (value: string) => void; placeholder?: string }) { return <input value={value} placeholder={placeholder} onChange={(event) => onChange(event.target.value)} />; }
function SecretInput({ value, onChange, visible, onToggle, placeholder }: { value: string; onChange: (value: string) => void; visible: boolean; onToggle: () => void; placeholder: string }) { return <div className="secret-input"><input type={visible ? 'text' : 'password'} value={value} placeholder={placeholder} autoComplete="off" onChange={(event) => onChange(event.target.value)} /><button type="button" onClick={onToggle}>{visible ? <EyeOff size={13} /> : <Eye size={13} />}</button></div>; }
function Select({ value, onChange, options }: { value: string; onChange: (value: string) => void; options: [string, string][] }) { return <select value={value} onChange={(event) => onChange(event.target.value)}>{options.map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select>; }
function NumberInput({ value, onChange, min = 256, max = 32768 }: { value: number; onChange: (value: number) => void; min?: number; max?: number }) { return <input type="number" min={min} max={max} value={value} onChange={(event) => onChange(Number(event.target.value))} />; }
function Toggle({ label, checked, onChange }: { label: string; checked: boolean; onChange: (value: boolean) => void }) { return <label className="settings-toggle"><input type="checkbox" checked={checked} onChange={(event) => onChange(event.target.checked)} /><i /><span>{label}</span></label>; }
function ActionRow({ saving, testing, onSave, onTest, testLabel = '测试连接' }: { saving: boolean; testing?: boolean; onSave: () => void; onTest?: () => void; testLabel?: string }) { return <div className="settings-actions"><button className="save" onClick={onSave} disabled={saving || testing}>{saving ? <Loader2 size={15} className="animate-spin" /> : <Save size={15} />}保存配置</button>{onTest && <button onClick={onTest} disabled={saving || testing}>{testing ? <Loader2 size={15} className="animate-spin" /> : <TestTube2 size={15} />}{testLabel}</button>}</div>; }
function getMessage(error: unknown) { return error instanceof Error ? error.message : '操作失败，请检查配置后重试。'; }
