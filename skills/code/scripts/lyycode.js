#!/usr/bin/env node
/**
 * lyycode：把一笔提交（或一段提交范围）生成“逐文件验证方案”网页。
 *
 * 用法：
 *   node lyycode.js hunks --repo <仓库> [--commit <提交> | --range <A..B>] [--work <工作目录>] [--force]
 *       读取 git diff，输出 hunks.md（每处变更的代码）和 notes.json 骨架（待填写的说明）。
 *   node lyycode.js build --repo <仓库> [--commit <提交> | --range <A..B>] [--work <工作目录>]
 *                         [--notes <notes.json>] [--out <输出.html> | --out-dir <输出目录>]
 *       校验 notes.json，并生成静态网页。
 *       默认输出到 E:\codeexplain（可用环境变量 LYYCODE_OUT_DIR 改），
 *       文件名为“时间_提交信息.html”，时间格式 yyyyMMddhhmm（12 小时制，下午 5:37 写作 0537）。
 *
 * 代码一律通过 git 读取（不读工作区文件），所以工作区文件被加密或有未提交改动都不影响结果。
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ---------- 参数 ----------
function parseArgs(argv) {
  const o = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--force") o.force = true;
    else if (a.startsWith("--")) o[a.slice(2)] = argv[++i];
    else o._.push(a);
  }
  return o;
}
const args = parseArgs(process.argv.slice(2));
const cmd = args._[0];
if (!["hunks", "build"].includes(cmd)) {
  console.error("用法：node lyycode.js <hunks|build> --repo <仓库> [--commit <提交> | --range <A..B>] [--work 目录] [--notes 文件] [--out 文件 | --out-dir 目录] [--force]");
  process.exit(2);
}
const REPO = path.resolve(args.repo || process.cwd());
const git = a => execFileSync("git", ["-c", "core.quotepath=false", ...a], { cwd: REPO, encoding: "utf8", maxBuffer: 512 << 20 });
const gitTry = a => { try { return git(a).trim(); } catch (e) { return ""; } };

// ---------- 确定比较范围 ----------
let diffArgs, id, subject;
if (args.range) {
  diffArgs = ["diff", args.range];
  id = args.range.replace(/[^\w.-]+/g, "_");
  const last = args.range.split("..").pop() || "HEAD";
  subject = gitTry(["log", "-1", "--format=%s", last]) || `提交范围 ${args.range}`;
} else {
  const commit = args.commit || "HEAD";
  const sha = gitTry(["rev-parse", "--verify", "-q", `${commit}^{commit}`]);
  if (!sha) { console.error(`找不到提交：${commit}（仓库 ${REPO}）`); process.exit(1); }
  id = sha.slice(0, 8);
  subject = gitTry(["log", "-1", "--format=%s", sha]);
  // 和第一个父提交比较（合并提交也能得到差异）；没有父提交（首个提交）时用 git show
  const parent = gitTry(["rev-parse", "--verify", "-q", `${sha}^`]);
  diffArgs = parent ? ["diff", parent, sha] : ["show", "--format=", sha];
}
const WORK = path.resolve(args.work || path.join(os.tmpdir(), "lyycode", id));
const NOTES = path.resolve(args.notes || path.join(WORK, "notes.json"));
// 网页默认输出目录：--out-dir > 环境变量 LYYCODE_OUT_DIR > E:\codeexplain
const OUT_DIR = path.resolve(args["out-dir"] || process.env.LYYCODE_OUT_DIR || "E:/codeexplain");
// 时间：yyyyMMddhhmm，小时用 12 小时制（下午 5:37 → 0537）
function stamp(d = new Date()) {
  const p = n => String(n).padStart(2, "0");
  const h = d.getHours() % 12 || 12;
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}${p(h)}${p(d.getMinutes())}`;
}
// 提交信息里 Windows 文件名不允许的字符换成全角或去掉，过长截断
const safeName = t => String(t).replace(/[\\/:*?"<>|\r\n\t]+/g, " ").replace(/\s+/g, " ").trim().replace(/[. ]+$/, "").slice(0, 80) || id;
const OUT = path.resolve(args.out || path.join(OUT_DIR, `${stamp()}_${safeName(subject)}.html`));

// ---------- 读取差异 ----------
const NO_EXPLAIN_EXT = /\.(xml|json|ya?ml|properties|gradle|kts|pro|md|txt|svg|html?|css|toml|ini|cfg|lock|plist|storyboard|xib|strings)$/i;
function collect() {
  const names = git([...diffArgs, "--no-renames", "--name-only"]).split(/\r?\n/).filter(Boolean);
  const stat = {};
  git([...diffArgs, "--no-renames", "--numstat"]).split(/\r?\n/).filter(Boolean).forEach(l => {
    const [a, d, ...rest] = l.split("\t");
    stat[rest.join("\t")] = [a, d];
  });
  return names.map((f, fi) => {
    const diff = git([...diffArgs, "--no-renames", "--", f]).split(/\r?\n/);
    const isNew = diff.some(l => l.startsWith("new file mode"));
    const isDeleted = diff.some(l => l.startsWith("deleted file mode"));
    const binary = diff.some(l => l.startsWith("Binary files") || l.startsWith("GIT binary patch"));
    const hunks = [];
    let cur = null;
    for (const l of diff) {
      if (l.startsWith("@@")) {
        const m = /@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@\s?(.*)/.exec(l);
        cur = { oldStart: +m[1], start: +m[3], ctx: m[5] || "", lines: [] };
        hunks.push(cur);
        continue;
      }
      if (!cur || l.startsWith("\\ No newline")) continue;
      cur.lines.push(l);
    }
    hunks.forEach(h => { while (h.lines.length && h.lines[h.lines.length - 1] === "") h.lines.pop(); });
    // 没有文本差异（二进制文件、只改权限等）：放一处占位变更，仍然要求写说明
    if (!hunks.length) hunks.push({ oldStart: 0, start: 0, ctx: "", lines: [], placeholder: binary ? "二进制文件，没有文本差异" : "没有文本差异" });
    const noExplainFile = binary || NO_EXPLAIN_EXT.test(f) || /(^|\/)res\//.test(f);
    hunks.forEach(h => {
      const changed = h.lines.filter(l => l[0] === "+" || l[0] === "-").map(l => l.slice(1).trim()).filter(Boolean);
      if (h.placeholder) h.kind = "resource";
      else if (changed.length && changed.every(l => /^(import|package|using|#include|from\s+\S+\s+import)\b/.test(l))) h.kind = "import";
      else if (noExplainFile) h.kind = "resource";
      else h.kind = "code";
    });
    const [add, del] = stat[f] || ["0", "0"];
    return { i: fi + 1, path: f, base: path.posix.basename(f), dir: path.posix.dirname(f) === "." ? "" : path.posix.dirname(f) + "/", isNew, isDeleted, binary, add, del, hunks };
  });
}

const esc = s => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
// 去掉多行代码共同的缩进，保留相对缩进
const dedent = s => { const ls = String(s).replace(/\t/g, "    ").replace(/^\n+|\s+$/g, "").split("\n"); const ind = Math.min(...ls.filter(l => l.trim()).map(l => l.match(/^ */)[0].length)); return ls.map(l => l.slice(ind)).join("\n"); };
// 语法项：字符串（旧格式），或 [[语法名, 文档位置, 解释], ...]
const synHtml = (v, lang, noLang) => {
  if (noLang) lang = "";
  if (!v || (Array.isArray(v) && !v.length) || !String(v).trim()) return "";
  if (!Array.isArray(v)) return `<span class="syn"><b>${lang}</b>${esc(v)}</span>`;
  return v.map(x => Array.isArray(x)
    ? `<span class="syn"><span class="sh">${lang ? `<b>${lang}</b>` : ""}<span class="sname">${esc(x[0] || "")}</span>${x[1] ? `<span class="sdoc">文档：${esc(x[1])}</span>` : ""}</span>${x[2] ? `<span class="stext">${esc(x[2])}</span>` : ""}</span>`
    : `<span class="syn"><b>${lang}</b>${esc(x)}</span>`).join("");
};
// 逐行说明：key 可带 "+ " / "- " 前缀，值为字符串（所有匹配行）或数组（第 n 次匹配用第 n 个）
const lineErrors = [];
// 显示宽度：中文等全角字符算 2 列
const dispLen = t => [...t].reduce((n, c) => n + (/[ᄀ-￿]/.test(c) ? 2 : 1), 0);
function lineComments(lines, map, where) {
  const out = [];
  if (!map || !lines) return out;
  for (const [rawKey, val] of Object.entries(map)) {
    const m = /^([+-]) (.*)$/.exec(rawKey);
    const mark = m ? m[1] : null, text = (m ? m[2] : rawKey).trim();
    const hits = [];
    lines.forEach((l, i) => { if ((!mark || l[0] === mark) && l.slice(1).trim() === text) hits.push(i); });
    if (!hits.length) { lineErrors.push(`${where}：逐行说明对不上代码行「${rawKey}」`); continue; }
    hits.forEach((i, k) => { const v = Array.isArray(val) ? val[k] : val; if (v) out[i] = v; });
  }
  return out;
}
const circled = n => "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳"[n - 1] || `(${n})`;
const VL = `<label class="vl" title="点击打勾"><input type="checkbox" class="vchk"><span class="bx"></span><span class="tx"></span></label>`;
const LANG = p => /\.kts?$/i.test(p) ? "Kotlin 语法" : /\.java$/i.test(p) ? "Java 语法" : /\.dart$/i.test(p) ? "Dart 语法" : /\.swift$/i.test(p) ? "Swift 语法" : /\.(ts|tsx)$/i.test(p) ? "TypeScript 语法" : /\.(js|jsx|mjs)$/i.test(p) ? "JavaScript 语法" : /\.py$/i.test(p) ? "Python 语法" : "语法";
const KIND_TEXT = { import: "导包，不用逐句解释", resource: "布局 / 资源 / 配置文件，不用逐句解释", code: "代码，需要逐句解释" };

// ---------- hunks：导出每处变更 + notes 骨架 ----------
if (cmd === "hunks") {
  const files = collect();
  fs.mkdirSync(WORK, { recursive: true });
  let md = `# ${id} ${subject}\n\n共 ${files.length} 个文件，${files.reduce((s, f) => s + f.hunks.length, 0)} 处变更。文件顺序与 git 显示一致。\n\n`;
  const skeleton = { title: `${id}「${subject}」逐文件验证方案`, alerts: [], files: {} };
  files.forEach(f => {
    md += `## [${f.i}/${files.length}] ${f.path}（+${f.add} −${f.del}，${f.hunks.length} 处变更${f.isNew ? "，新文件" : ""}${f.isDeleted ? "，已删除" : ""}）\n\n`;
    skeleton.files[f.path] = f.hunks.map((h, hi) => {
      md += `### 变更 ${hi + 1}（第 ${h.start} 行起，${KIND_TEXT[h.kind]}）\n\n`;
      md += h.placeholder ? `（${h.placeholder}）\n\n` : "```diff\n" + h.lines.join("\n") + "\n```\n\n";
      const n = { hunk: hi + 1, start: h.start, kind: h.kind, why: "", verify: "" };
      if (h.kind === "import") { n.why = "导包：下面新增的代码要用到这些类 / 方法。"; n.verify = "编译通过即可。"; }
      if (h.kind === "code") { n.lines = {}; n.syntax = []; }
      return n;
    });
  });
  fs.writeFileSync(path.join(WORK, "hunks.md"), md);
  if (fs.existsSync(NOTES) && !args.force) {
    console.log(`notes 已存在，没有覆盖：${NOTES}（要重建骨架请加 --force）`);
  } else {
    fs.writeFileSync(NOTES, JSON.stringify(skeleton, null, 2));
    console.log(`notes 骨架：${NOTES}`);
  }
  console.log(`变更清单：${path.join(WORK, "hunks.md")}`);
  console.log(`文件 ${files.length} 个，变更 ${files.reduce((s, f) => s + f.hunks.length, 0)} 处：`);
  files.forEach(f => console.log(`  ${String(f.i).padStart(3)}  ${f.path}  ${f.hunks.map(h => h.kind[0]).join("")}`));
  console.log("（每个字母是一处变更：i=导包 r=布局/资源 c=代码）");
  process.exit(0);
}

// ---------- build：生成网页 ----------
if (!fs.existsSync(NOTES)) { console.error(`找不到 notes 文件：${NOTES}，请先运行 hunks`); process.exit(1); }
const notes = NOTES.endsWith(".js") ? require(NOTES) : JSON.parse(fs.readFileSync(NOTES, "utf8"));
const files = collect();
const byBase = {};
Object.keys(notes.files || {}).forEach(k => { const b = path.posix.basename(k); (byBase[b] = byBase[b] || []).push(k); });
const errors = [], warns = [];
let nav = "", rows = "", totalA = 0, totalD = 0, totalH = 0;

files.forEach(f => {
  let n = (notes.files || {})[f.path];
  if (!n && byBase[f.base] && byBase[f.base].length === 1) n = notes.files[byBase[f.base][0]];
  if (!n) { errors.push(`${f.path}：notes 里没有这个文件`); return; }
  if (n.length !== f.hunks.length) { errors.push(`${f.path}：有 ${f.hunks.length} 处变更，notes 里写了 ${n.length} 处`); return; }
  n.forEach((x, hi) => {
    if (!x.why || !String(x.why).trim()) errors.push(`${f.path} 变更 ${hi + 1}：缺少 why（修改原因）`);
    if (!x.verify || !String(x.verify).trim()) errors.push(`${f.path} 变更 ${hi + 1}：缺少 verify（如何验证）`);
    const isCode = f.hunks[hi].kind === "code";
    if (isCode && !(x.lines && Object.keys(x.lines).length) && !(x.explain && x.explain.length)) warns.push(`${f.path} 变更 ${hi + 1}：是代码变更，但没有逐行说明（lines）`);
    if (isCode && !(x.syntax && x.syntax.length) && !(x.explain && x.explain.some(e => e[2] && String(e[2]).trim()))) warns.push(`${f.path} 变更 ${hi + 1}：没有 Kotlin 语法说明（syntax）`);
    (x.syntax || []).forEach((e, ei) => { if (!Array.isArray(e) || e.length < 3) errors.push(`${f.path} 变更 ${hi + 1}：syntax 第 ${ei + 1} 项要写成 ["语法名", "文档位置", "解释"]`); });
    (x.explain || []).forEach((e, ei) => { if (!Array.isArray(e) || e.length < 2) errors.push(`${f.path} 变更 ${hi + 1}：explain 第 ${ei + 1} 项要写成 ["代码", "含义", [["语法名", "文档位置", "解释"], ...]]`); });
  });
  const fileWarn = n.some(x => x.warn);
  totalA += +f.add || 0; totalD += +f.del || 0; totalH += f.hunks.length;
  const tags = (f.isNew ? '<span class="new">新文件</span>' : "") + (f.isDeleted ? '<span class="del">已删除</span>' : "") + (fileWarn ? '<span class="warnt">❗</span>' : "");
  nav += `<div class="ni" data-f="${esc(f.path)}"><a href="#f${f.i}"><span class="no">${f.i}</span><span class="nm">${fileWarn ? "❗ " : ""}${esc(f.base)}</span></a>` +
    `${VL}</div>\n`;
  rows += `<tbody class="file" id="f${f.i}" data-f="${esc(f.path)}">\n` +
    `<tr class="fh"><td colspan="2"><span class="idx">${f.i} / ${files.length}</span><span class="base">${esc(f.base)}</span>` +
    `<span class="dir">${esc(f.dir)}</span><span class="cnt">${f.hunks.length} 处变更</span>${tags}${VL}</td></tr>\n`;
  f.hunks.forEach((h, hi) => {
    let ol = h.oldStart, nl = h.start;
    const x = n[hi];
    const cm = lineComments(h.lines, x.lines, `${f.path} 变更 ${hi + 1}`);
    // 同一处变更里的说明对齐：取有说明的代码行里最长的那行（最多 90 列）
    const cmCol = Math.min(90, Math.max(0, ...h.lines.map((l, i) => cm[i] ? dispLen(l.slice(1).replace(/s+$/, "")) : 0))) + 4;
    const code = h.placeholder
      ? `<tr class="c"><td class="g"></td><td class="g"></td><td class="m"></td><td class="s">（${esc(h.placeholder)}）</td></tr>`
      : h.lines.map((l, li) => {
        const t = l[0] === "+" ? "a" : l[0] === "-" ? "d" : "c";
        const o = t === "a" ? "" : ol, nn = t === "d" ? "" : nl;
        if (t !== "a") ol++;
        if (t !== "d") nl++;
        return `<tr class="${t}"><td class="g">${o}</td><td class="g">${nn}</td><td class="m">${t === "a" ? "+" : t === "d" ? "−" : ""}</td><td class="s">${esc(l.slice(1)) || " "}${cm[li] ? `${" ".repeat(Math.max(4, cmCol - dispLen(l.slice(1).replace(/s+$/, ""))))}<span class="cm">// ${esc(cm[li])}</span>` : ""}</td></tr>`;
      }).join("");
    const syn = x.syntax && x.syntax.length
      ? `<div class="k2">${LANG(f.path)}</div>${synHtml(x.syntax, LANG(f.path), true)}<div class="k2">为什么这样改</div>`
      : "";
    const ex = syn ? syn : x.explain && x.explain.length
      ? `<div class="k2">代码含义</div><ol class="ex">${x.explain.map(e => `<li><pre class="exc">${esc(dedent(e[0]))}</pre><span class="mean">${esc(e[1])}</span>` +
        synHtml(e[2], LANG(f.path)) + `</li>`).join("")}</ol><div class="k2">为什么这样改</div>`
      : "";
    const fold = h.kind === "import";
    const head = `<span class="k">变更 ${circled(hi + 1)}</span><span class="c">${h.placeholder ? "" : fold ? `导包 · ${h.lines.filter(l => l[0] === "+" || l[0] === "-").length} 行改动（点击展开）` : `第 ${h.start} 行起　${esc(h.ctx)}`}</span>`;
    const wc = x.warn ? " warn" : "";
    rows += `<tr class="hk-code${wc}"><td class="cd" colspan="2">` + (fold
      ? `<details class="box fold"><summary class="hd">${head}</summary><div class="sc"><table class="code">${code}</table></div></details></td>`
      : `<div class="box"><div class="hd">${head}</div><div class="sc"><table class="code">${code}</table></div></div></td>`) + `</tr>\n` +
      `<tr class="hk-note${wc}"><td class="rs"><span class="k">变更 ${circled(hi + 1)} · 修改原因（为什么这样改）</span>${ex}<div class="why">${x.why}</div></td>` +
      `<td class="vf"><span class="k">变更 ${circled(hi + 1)} · 如何验证（页面如何进入）</span>${x.verify}</td></tr>\n`;
  });
  rows += "</tbody>\n";
});

errors.push(...lineErrors);
if (errors.length) {
  console.error(`notes 有 ${errors.length} 个问题，没有生成网页：`);
  errors.forEach(e => console.error("  - " + e));
  process.exit(1);
}
const title = args.title || notes.title || `${id}「${subject}」逐文件验证方案`;
const alerts = (notes.alerts || []).map(a => `<div class="alert${a.type === "info" ? " info" : ""}">${a.html}</div>`).join("\n    ");
const meta = `共 ${files.length} 个文件 · ${totalH} 处变更 · +${totalA} / −${totalD} · 行号为提交后的新文件行号`;
const tpl = fs.readFileSync(path.join(__dirname, "..", "assets", "template.html"), "utf8");
const html = tpl
  .replace("<!--PAGETITLE-->", () => esc(`${id} 逐文件验证`))
  .replace("<!--TITLE-->", () => esc(title))
  .replace("<!--META-->", () => meta)
  .replace("<!--ALERTS-->", () => alerts)
  .replace("<!--NAV-->", () => nav)
  .replace("<!--ROWS-->", () => rows)
  .replace(/<!--TOTAL-->/g, () => String(files.length))
  .replace("<!--KEY-->", () => id);
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, html);
console.log(`已生成：${OUT}`);
console.log(`文件 ${files.length} 个 · 变更 ${totalH} 处 · +${totalA} / −${totalD} · ${(html.length / 1024) | 0} KB`);
if (warns.length) {
  console.log(`提醒（不影响生成，共 ${warns.length} 条）：`);
  warns.forEach(w => console.log("  - " + w));
}
