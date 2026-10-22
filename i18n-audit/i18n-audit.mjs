/**
 * i18n 审计：找出「该切换语言但没切换」的可见文案（opus 方案 · 纯 HTTP 版）
 *
 * 为什么不用 Chrome：平台页面是**服务端直出 HTML**（铁律①），无需渲染即可拿到全部可见文字，
 * 纯 HTTP 更快更轻，也不会撞上本机内存不足。
 *
 * 用法：
 *   BASE=https://aaasagent.xyz node scripts/i18n-audit.mjs
 *   BASE=http://127.0.0.1:8787 node scripts/i18n-audit.mjs
 */

const BASE = process.env.BASE ?? "https://aaasagent.xyz";
const ROUTES = [
  "/", "/templates", "/templates/collections", "/templates/search", "/docs", "/docs/api",
  "/docs/compliance", "/beta", "/register", "/login", "/kyc", "/contact", "/privacy", "/terms",
  "/handbook", "/benchmarks", "/market",
];

// 允许出现的外来词（品牌 / 术语 / 技术名）
const ALLOW = [
  "Agent-as-a-Service", "AI Agent", "Boost for agents",
  "API", "SDK", "MCP", "BYOK", "KYC", "LLM", "JSON", "HTTP", "HTTPS", "Cloudflare",
  "Worker", "Workers", "D1", "KV", "OpenClaw", "Hermes", "Codex", "Claude", "GPT",
  "DeepSeek", "MiniMax", "Qwen", "PDF", "CSV", "URL", "ID", "Token", "Prompt", "Agent", "Agents",
  // 法定信息：中英版都必须显示原文，不能翻译
  "上海卷不动你科技有限公司", "上海卷不动你科技", "沪ICP备2026041302号", "ICP备",
  // 语言切换按钮自身（英文页也要显示「中文」这个选项名）
  "中文", "简体中文",
];

const CJK = /[\u3400-\u9fff\uf900-\ufaff]/g;

/** 从 HTML 抽可见文本（去 script/style/code/pre，去标签，解实体） */
function extractText(html) {
  let s = html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<pre[\s\S]*?<\/pre>/gi, " ")
    .replace(/<code[\s\S]*?<\/code>/gi, " ")
    .replace(/<svg[\s\S]*?<\/svg>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ");
  // 抽属性里的可见文案
  const attrs = [];
  for (const m of s.matchAll(/(?:aria-label|placeholder|title|alt)="([^"]{2,120})"/g)) attrs.push(m[1]);
  s = s.replace(/<[^>]+>/g, "\n");
  s = s.replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
  const lines = [...s.split("\n"), ...attrs].map((x) => x.trim()).filter((x) => x.length > 1);
  return lines;
}

function strip(text) {
  let s = text;
  for (const a of ALLOW) s = s.split(a).join(" ");
  s = s.replace(/https?:\/\/\S+|\S+@\S+|\/[\w\-/{}:.]*|\b\w*[_.$]\w+\b|\b[a-z]+[A-Z]\w*\b|\bv?\d[\d.]*\b/g, " ");
  return s;
}

function judge(lang, text) {
  const s = strip(text);
  if (!s.trim()) return null;
  const cjk = (s.match(CJK) ?? []).length;
  const words = s.match(/[A-Za-z]{2,}/g) ?? [];
  if (lang === "en" && cjk > 0) return { level: "error", why: `英文页含 ${cjk} 个汉字` };
  if (lang === "zh" && words.length >= 4 && cjk < words.length) {
    return { level: "warn", why: `中文页疑似英文句子(${words.length}词/${cjk}汉字)` };
  }
  return null;
}

async function getText(url) {
  const res = await fetch(url, { headers: { "User-Agent": "aaas-i18n-audit" } });
  const html = await res.text();
  return extractText(html);
}

const issues = [];
let scanned = 0;

for (const route of ROUTES) {
  const byLang = {};
  for (const lang of ["zh", "en"]) {
    const url = `${BASE}${route}${route.includes("?") ? "&" : "?"}lang=${lang}`;
    let lines;
    try {
      lines = await getText(url);
    } catch (e) {
      issues.push({ level: "warn", url, sel: "-", text: "", why: `加载失败 ${String(e).slice(0, 40)}` });
      continue;
    }
    scanned += lines.length;
    byLang[lang] = lines;
    for (const t of lines) {
      const j = judge(lang, t);
      if (j) issues.push({ level: j.level, url, sel: "-", text: t.slice(0, 80), why: j.why });
    }
  }
  // 差异规则：同一行文本在 zh/en 两版都出现且完全相同 → 疑未切换
  const zhSet = new Set(byLang.zh ?? []);
  const enSet = new Set(byLang.en ?? []);
  for (const t of zhSet) {
    if (!enSet.has(t)) continue;
    const meaningful = (strip(t).match(/[A-Za-z]{2,}|[\u3400-\u9fff]/g) ?? []).length;
    if (meaningful >= 3) {
      issues.push({ level: "warn", url: `${BASE}${route}`, sel: "-", text: t.slice(0, 80), why: "zh/en 文本相同，疑未切换" });
    }
  }
}

// 去重
const uniq = new Map();
for (const i of issues) uniq.set(`${i.level}|${i.url}|${i.text}|${i.why}`, i);
const list = [...uniq.values()];
const errors = list.filter((i) => i.level === "error");
const warns = list.filter((i) => i.level === "warn");

console.log(`\n扫描 ${ROUTES.length} 页 × 2 语言 · 文本行 ${scanned}`);
console.log(`error: ${errors.length} · warn: ${warns.length}\n`);
for (const i of [...errors, ...warns].slice(0, 50)) {
  console.log(`[${i.level}] ${i.url.replace(BASE, "")}\n    "${i.text}"\n    → ${i.why}`);
}
if (list.length > 50) console.log(`\n…另有 ${list.length - 50} 条未显示`);
process.exitCode = errors.length > 0 ? 1 : 0;
