#!/usr/bin/env node
/**
 * kte：导出 git 里还没提交的修改，给“逐句解释”用。
 *
 *   node kte.js --list [--repo <仓库>] [--staged]
 *       只列出有未提交修改的文件（序号、状态、增删行数），用来问用户要解释哪几个。
 *   node kte.js --files <名字,名字> [--repo <仓库>] [--staged] [--out <hunks.md>]
 *       导出这几个文件的变更清单。名字可以是类名（DeviceCaroActivity）、文件名（strings.xml）、
 *       相对路径、目录或绝对路径，逗号分隔，只在有未提交修改的文件里找。--paths 是同义参数。
 *       不传 --files 时导出全部未提交的修改。
 *   node kte.js fmt [--width 80] < 带说明的代码行
 *       把“代码行 ## 说明”排成回答里用的代码块：去掉行号、去掉共同缩进、说明对齐，
 *       每行不超过 --width 列（中文算 2 列），放不下的说明改写在代码上一行（// ↓ 说明）。
 *       多段代码用 “===== 语言” 分隔（默认 kotlin）。
 *
 * 范围：已暂存 + 未暂存（git diff HEAD）+ 未跟踪的新文件；--staged 只看已暂存的（git diff --cached）。
 * hunks.md 默认放在系统临时目录 kte/<仓库名>/ 下，不写进仓库。
 * 文件按路径排序（和 git status 一致），每处变更一个带行号的 diff 代码块，
 * 标出类型（导包 / 资源 / 代码）、新增和删除的行号范围、读代码时要提醒的问题（TODO 格式、和设计相关的注释）。
 * 新文件开头的 package / import 单独拆成一处“导包”变更。
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ---------- 参数 ----------
const args = { _: [] };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--staged" || a === "--list") args[a.slice(2)] = true;
  else if (a.startsWith("--")) args[a.slice(2)] = argv[++i];
  else args._.push(a);
}

// 显示宽度：中文等全角字符算 2 列
const dispW = s => [...s].reduce((n, c) => n + (/[ᄀ-￿]/.test(c) ? 2 : 1), 0);

// ---------- fmt：排成回答里用的代码块 ----------
if (args._[0] === "fmt") {
  const WIDTH = +args.width || 80;
  const input = fs.readFileSync(0, "utf8").replace(/\r/g, "").replace(/\t/g, "    ");
  const blocks = [];
  let cur = null;
  for (const raw of input.split("\n")) {
    const h = /^=====\s*(\S*)/.exec(raw);
    if (h) { cur = { lang: h[1] || "kotlin", lines: [] }; blocks.push(cur); continue; }
    if (!cur) { cur = { lang: "kotlin", lines: [] }; blocks.push(cur); }
    cur.lines.push(raw);
  }
  const tooWide = [];
  const out = blocks.map(b => {
    while (b.lines.length && !b.lines[b.lines.length - 1].trim()) b.lines.pop();
    while (b.lines.length && !b.lines[0].trim()) b.lines.shift();
    const rows = b.lines.map(l => {
      const i = l.lastIndexOf(" ## ");
      let code = i >= 0 ? l.slice(0, i) : l;
      const cm = i >= 0 ? l.slice(i + 4).trim() : "";
      let mark = " ";
      const m = /^([+\- ])\s*\d+ \| ?(.*)$/.exec(code); // hunks.md 里带行号的行
      if (m) { mark = m[1]; code = m[2]; }
      else if (/^[+-] /.test(code)) { mark = code[0]; code = code.slice(2); }
      return { mark, code: code.replace(/\s+$/, ""), cm };
    });
    const lead = s => s.match(/^ */)[0].length;
    const ind = Math.min(...rows.filter(r => r.code.trim()).map(r => lead(r.code)));
    // 有 +/- 的才留出标记列；语法小课这类普通代码不加
    const marked = rows.some(r => r.mark !== " ");
    const pre = r => (marked ? `${r.mark} ` : "");
    const gap = marked ? "  " : "";
    rows.forEach(r => { r.code = r.code.slice(Math.min(ind, lead(r.code))); r.w = pre(r).length + dispW(r.code); });
    // 说明对齐到同一列：试每个可能的列，选能写在行尾的说明最多的那个（一样多时选靠左的）
    const cand = rows.filter(r => r.cm);
    let inline = [], col = 0;
    [...new Set(cand.map(r => r.w + 4))].sort((a, b) => a - b).forEach(c => {
      const fit = cand.filter(r => r.w + 4 <= c && c + 3 + dispW(r.cm) <= WIDTH);
      if (fit.length > inline.length) { inline = fit; col = c; }
    });
    // 对不齐的：代码后面空 4 格写说明；还是放不下，才改写在代码上一行（// ↓ 说明）
    const lines = [];
    rows.forEach(r => {
      const text = pre(r) + r.code;
      if (!r.cm) lines.push(text);
      else if (inline.includes(r)) lines.push(text + " ".repeat(col - r.w) + `// ${r.cm}`);
      else if (r.w + 4 + 3 + dispW(r.cm) <= WIDTH) lines.push(text + "    " + `// ${r.cm}`);
      else { lines.push(`${gap}${" ".repeat(lead(r.code))}// ↓ ${r.cm}`); lines.push(text); }
    });
    lines.forEach(l => { if (dispW(l) > WIDTH) tooWide.push(l.trim()); });
    return "```" + b.lang + "\n" + lines.join("\n") + "\n```";
  });
  console.log(out.join("\n\n"));
  if (tooWide.length) {
    console.error(`有 ${tooWide.length} 行超过 ${WIDTH} 列（代码本身太长，没法再缩短）：`);
    tooWide.forEach(l => console.error("  " + l));
  }
  process.exit(0);
}

const run = (cwd, a) => execFileSync("git", ["-c", "core.quotepath=false", ...a],
  { cwd, encoding: "utf8", maxBuffer: 512 << 20, stdio: ["ignore", "pipe", "pipe"] }); // 不显示 git 的换行符警告
let REPO;
try {
  REPO = path.resolve(run(path.resolve(args.repo || process.cwd()), ["rev-parse", "--show-toplevel"]).trim());
} catch (e) {
  console.error(`不是 git 仓库：${path.resolve(args.repo || process.cwd())}`);
  process.exit(1);
}
const git = a => run(REPO, a);
const gitTry = a => { try { return git(a); } catch (e) { return ""; } };

const hasHead = !!gitTry(["rev-parse", "--verify", "-q", "HEAD"]).trim();
const base = args.staged || !hasHead ? ["diff", "--cached"] : ["diff", "HEAD"];
const scope = args.staged ? "已暂存" : "已暂存 + 未暂存 + 未跟踪";
const OUT = path.resolve(args.out || path.join(os.tmpdir(), "kte", path.basename(REPO), "hunks.md"));

// ---------- 每个文件的状态（git status） ----------
const status = {};
const st = gitTry(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split("\0");
for (let i = 0; i < st.length; i++) {
  const r = st[i];
  if (r.length < 4) continue;
  const x = r[0], y = r[1], p = r.slice(3);
  if (x === "R" || x === "C") i++; // 改名记录后面还跟着旧路径
  const tags = [];
  if (x === "?") tags.push("未跟踪");
  else {
    if (x !== " ") tags.push("已暂存");
    if (y !== " ") tags.push(x !== " " ? "暂存后又改过" : "未暂存");
  }
  status[p] = tags.join("，");
}

// ---------- 有未提交修改的文件 ----------
let files = [];
const stat = {};
git([...base, "--no-renames", "--numstat", "-z"]).split("\0").forEach(l => {
  const m = /^(\S+)\t(\S+)\t(.+)$/.exec(l);
  if (m) stat[m[3]] = [m[1], m[2]];
});
git([...base, "--no-renames", "--name-only", "-z"]).split("\0").filter(Boolean).forEach(f => {
  const [add, del] = stat[f] || ["-", "-"];
  files.push({ path: f, add, del, untracked: false });
});
if (!args.staged) {
  gitTry(["ls-files", "--others", "--exclude-standard", "-z"]).split("\0").filter(Boolean).forEach(f => {
    const buf = fs.readFileSync(path.join(REPO, f));
    const binary = buf.subarray(0, 8000).includes(0);
    let n = 0;
    if (!binary) { const s = buf.toString("utf8"); n = s ? s.split("\n").length - (s.endsWith("\n") ? 1 : 0) : 0; }
    files.push({ path: f, add: binary ? "-" : String(n), del: binary ? "-" : "0", untracked: true });
  });
}
files.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
files.forEach(f => { f.status = status[f.path] || (args.staged ? "已暂存" : ""); });

const fileLine = (f, i) => `  ${String(i + 1).padStart(3)}  ${f.path}  [${f.status || "-"}]  +${f.add} −${f.del}`;
if (!files.length) {
  console.log(`没有未提交的修改（范围：${scope}）。`);
  process.exit(0);
}
if (args.list) {
  console.log(`有未提交修改的文件（范围：${scope}，共 ${files.length} 个）：`);
  files.forEach((f, i) => console.log(fileLine(f, i)));
  process.exit(0);
}

// ---------- 按名字挑文件 ----------
const terms = (args.files || args.paths || "").split(",").map(s => s.trim()).filter(Boolean);
if (terms.length) {
  const repoFwd = REPO.replace(/\\/g, "/").toLowerCase();
  const norm = t => {
    let s = t.replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/+$/, "");
    if (s.toLowerCase().startsWith(repoFwd + "/")) s = s.slice(repoFwd.length + 1);
    return s;
  };
  const hit = (f, t) => {
    const b = path.posix.basename(f.path);
    return f.path === t || f.path.startsWith(t + "/") || f.path.endsWith("/" + t) || b === t || b.replace(/\.[^.]+$/, "") === t;
  };
  const picked = new Set(), missing = [];
  terms.map(norm).forEach(t => {
    const m = files.filter(f => hit(f, t));
    if (!m.length) missing.push(t);
    m.forEach(f => picked.add(f));
  });
  if (missing.length) {
    console.error(`在未提交的修改里找不到：${missing.join("、")}`);
    console.error(`有未提交修改的文件（范围：${scope}）：`);
    files.forEach((f, i) => console.error(fileLine(f, i)));
    process.exit(1);
  }
  files = files.filter(f => picked.has(f));
}

// ---------- 读取每个文件的差异 ----------
function parseDiff(text) {
  const diff = text.split(/\r?\n/);
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
  return {
    hunks,
    isNew: diff.some(l => l.startsWith("new file mode")),
    isDeleted: diff.some(l => l.startsWith("deleted file mode")),
    binary: diff.some(l => l.startsWith("Binary files") || l.startsWith("GIT binary patch")),
  };
}

files.forEach(f => {
  if (!f.untracked) { Object.assign(f, parseDiff(git([...base, "--no-renames", "--", f.path]))); return; }
  const buf = fs.readFileSync(path.join(REPO, f.path));
  f.isNew = true;
  f.binary = buf.subarray(0, 8000).includes(0);
  f.hunks = [];
  if (f.binary) return;
  const lines = buf.toString("utf8").replace(/\r/g, "").split("\n");
  if (lines.length && lines[lines.length - 1] === "") lines.pop();
  if (lines.length) f.hunks.push({ oldStart: 0, start: 1, ctx: "", lines: lines.map(l => "+" + l) });
});

// ---------- 整理每处变更 ----------
const NO_EXPLAIN_EXT = /\.(xml|json|ya?ml|properties|gradle|kts|pro|md|txt|svg|html?|css|toml|ini|cfg|lock|plist|storyboard|xib|strings)$/i;
const HEADER_LINE = /^(package|import)\b/;
const DESIGN_NOTE = /^(\/\/|\/\*|\*|#|<!--).*(设计|figma|\bios\b)/i;
const isComment = t => /^(\/\/|\/\*|\*|#|<!--)/.test(t);
const KIND_TEXT = { import: "导包，回答里不显示", resource: "布局 / 资源 / 配置文件，不逐句解释", code: "代码，需要逐句解释" };

files.forEach(f => {
  // 新文件：开头的 package / import 拆成单独一处“导包”变更
  if (f.isNew && f.hunks.length === 1) {
    const h = f.hunks[0];
    let i = 0;
    while (i < h.lines.length && (HEADER_LINE.test(h.lines[i].slice(1).trim()) || !h.lines[i].slice(1).trim())) i++;
    const hasHeader = h.lines.slice(0, i).some(l => HEADER_LINE.test(l.slice(1).trim()));
    if (hasHeader && i < h.lines.length) {
      f.hunks = [
        { oldStart: 0, start: h.start, ctx: "", lines: h.lines.slice(0, i) },
        { oldStart: 0, start: h.start + i, ctx: "", lines: h.lines.slice(i) },
      ];
    }
  }
  if (!f.hunks.length) f.hunks.push({ oldStart: 0, start: 0, ctx: "", lines: [], placeholder: f.binary ? "二进制文件，没有文本差异" : "没有文本差异" });
  const noExplainFile = f.binary || NO_EXPLAIN_EXT.test(f.path) || /(^|\/)res\//.test(f.path);
  f.hunks.forEach(h => {
    const changed = h.lines.filter(l => l[0] === "+" || l[0] === "-").map(l => l.slice(1).trim()).filter(Boolean);
    if (h.placeholder) h.kind = "resource";
    else if (changed.length && changed.every(l => /^(import|package|using|#include|from\s+\S+\s+import)\b/.test(l))) h.kind = "import";
    else if (noExplainFile) h.kind = "resource";
    else h.kind = "code";
    const added = h.lines.filter(l => l[0] === "+").map(l => l.slice(1).trim());
    h.todo = added.filter(t => isComment(t) && /\bTODO\b/i.test(t) && !/^\/\/TODO jade\s/.test(t));
    h.design = added.filter(t => DESIGN_NOTE.test(t));
  });
});

// 带行号：+ 和空格开头的是修改后的新行号，- 开头的是修改前的旧行号
function numbered(h) {
  let ol = h.oldStart, nl = h.start;
  return h.lines.map(l => {
    const m = l[0] === "+" ? "+" : l[0] === "-" ? "-" : " ";
    let n;
    if (m === "-") n = ol++;
    else if (m === "+") n = nl++;
    else { n = nl; ol++; nl++; }
    return `${m}${String(n).padStart(5)} | ${l.slice(1).replace(/\t/g, "    ")}`;
  });
}

// 行号范围：新增行（修改后的行号）和删除行（修改前的行号），给回答里的标题用
function ranges(h) {
  let ol = h.oldStart, nl = h.start;
  const add = [], del = [];
  h.lines.forEach(l => {
    if (l[0] === "-") del.push(ol++);
    else if (l[0] === "+") add.push(nl++);
    else { ol++; nl++; }
  });
  const r = a => (a.length ? (a[0] === a[a.length - 1] ? `第 ${a[0]} 行` : `第 ${a[0]}–${a[a.length - 1]} 行`) : "");
  return [add.length ? `新增 ${r(add)}` : "", del.length ? `删除 原${r(del)}` : ""].filter(Boolean).join("，") || `第 ${h.start} 行起`;
}

// ---------- 输出 hunks.md ----------
const totalH = files.reduce((s, f) => s + f.hunks.length, 0);
const sum = k => files.reduce((s, f) => s + (+f[k] || 0), 0);
const which = terms.length ? `，只看 ${terms.join("、")}` : "，全部文件";
const problems = [];
let md = `# 未提交的修改（范围：${scope}${which}）\n\n` +
  `仓库：${REPO}\n共 ${files.length} 个文件，${totalH} 处变更，+${sum("add")} / −${sum("del")}。文件顺序和 git status 一致。\n` +
  `行号：+ 和空格开头的行是修改后的新行号，- 开头的行是修改前的旧行号。\n\n`;
files.forEach((f, fi) => {
  const tags = [f.status, f.isNew ? "新文件" : "", f.isDeleted ? "已删除" : "", f.binary ? "二进制" : ""].filter(Boolean).join(" · ");
  md += `## [${fi + 1}/${files.length}] ${f.path}（${tags ? tags + " · " : ""}+${f.add} −${f.del} · ${f.hunks.length} 处变更）\n\n`;
  if (f.binary && !NO_EXPLAIN_EXT.test(f.path) && !/(^|\/)res\//.test(f.path) && !/\.(png|jpe?g|webp|gif|ttf|otf|jar|aar|so)$/i.test(f.path)) {
    md += `> ⚠ git 把它当成二进制文件。如果它本来是代码，可能被公司加密软件加密了，git 读不到明文。\n\n`;
    problems.push(`${f.path}：git 读到的是二进制，可能被加密`);
  }
  f.hunks.forEach((h, hi) => {
    md += `### 变更 ${hi + 1}（${h.placeholder ? "没有文本差异" : ranges(h)}，${KIND_TEXT[h.kind]}）${h.ctx ? "　" + h.ctx : ""}\n\n`;
    md += h.placeholder ? `（${h.placeholder}）\n\n` : "```diff\n" + numbered(h).join("\n") + "\n```\n\n";
    h.todo.forEach(t => { md += `> ⚠ TODO 不是 \`//TODO jade 内容\` 格式：\`${t}\`\n`; problems.push(`${f.path} 变更 ${hi + 1}：TODO 格式 → ${t}`); });
    h.design.forEach(t => { md += `> ⚠ 新增了和设计相关的注释：\`${t}\`\n`; problems.push(`${f.path} 变更 ${hi + 1}：设计相关注释 → ${t}`); });
    if (h.todo.length || h.design.length) md += "\n";
  });
});
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, md);

console.log(`变更清单：${OUT}`);
console.log(`范围：${scope}${which}`);
console.log(`文件 ${files.length} 个 · 变更 ${totalH} 处（代码 ${files.reduce((s, f) => s + f.hunks.filter(h => h.kind === "code").length, 0)} 处）· +${sum("add")} / −${sum("del")}`);
files.forEach((f, fi) => console.log(`${fileLine(f, fi)}  ${f.hunks.map(h => h.kind[0]).join("")}`));
console.log("（最后一列每个字母是一处变更：i=导包 r=布局/资源 c=代码）");
if (problems.length) {
  console.log(`读代码前要留意的问题（共 ${problems.length} 条）：`);
  problems.forEach(p => console.log("  - " + p));
}
