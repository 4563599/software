#!/usr/bin/env node
/**
 * Kotlin 中文文档（PDF）本地检索。
 *
 *   node kotlin-docs.js build <pdf> [--out <目录>]
 *       用 pdftotext 把 PDF 转成文本，按章节切分，生成：
 *         chapters.tsv            章节名 \t 起始页 \t 结束页 \t 文件名
 *         chapters/NNNN_章节名.txt  每章正文，每页前面有 [p.页码] 标记
 *       2000 多页约 10 秒。只需要在文档更新时重跑一次。
 *
 *   node kotlin-docs.js find <关键字...> [--dir <目录>] [--chapter <章节名片段>] [--max 8] [--context 120]
 *       在已切分的文本里搜索，输出“章节 · 页码 · 上下文片段”。多个关键字表示同时出现在同一页。
 *       用它确认某个语法在文档哪一章、哪一页，比打开 PDF 省时间。
 *
 * 默认目录：本脚本所在技能的 references/kotlin-docs。
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const DEFAULT_DIR = path.join(__dirname, "..", "references", "kotlin-docs");
const argv = process.argv.slice(2);
const cmd = argv[0];
const opt = {}; const rest = [];
for (let i = 1; i < argv.length; i++) {
  if (argv[i].startsWith("--")) opt[argv[i].slice(2)] = argv[++i]; else rest.push(argv[i]);
}

function findPdftotext() {
  const cands = ["pdftotext", "C:/Program Files/Git/mingw64/bin/pdftotext.exe", "/mingw64/bin/pdftotext"];
  for (const c of cands) { try { execFileSync(c, ["-v"], { stdio: "ignore" }); return c; } catch (e) { if (e.status !== undefined && e.status !== null) return c; } }
  console.error("找不到 pdftotext（Git for Windows 自带，在 C:\\Program Files\\Git\\mingw64\\bin）。"); process.exit(1);
}

if (cmd === "build") {
  const pdf = rest[0];
  if (!pdf || !fs.existsSync(pdf)) { console.error("用法：node kotlin-docs.js build <pdf路径> [--out 目录]"); process.exit(2); }
  const out = path.resolve(opt.out || DEFAULT_DIR);
  const tmp = path.join(out, "_full.txt");
  fs.mkdirSync(path.join(out, "chapters"), { recursive: true });
  execFileSync(findPdftotext(), ["-enc", "UTF-8", pdf, tmp], { stdio: "inherit" });
  const pages = fs.readFileSync(tmp, "utf8").split("\f");
  fs.unlinkSync(tmp);
  // 每页第一行是页眉（当前章节名）；有时页眉和正文挤在同一行，所以用“已知的短页眉”做前缀匹配
  const firstLine = pages.map(p => (p.split("\n").map(l => l.trim()).find(Boolean) || ""));
  // 只认目录里出现过的页眉，避免把正文当成章节名
  const toc = pages.slice(0, 15).join(" ").replace(/\s+/g, " ");
  const titles = [...new Set(firstLine.filter(t => t && t.length <= 30 && !/^\d+$/.test(t) && toc.includes(t)))].sort((a, b) => b.length - a.length);
  let cur = "（目录）";
  const chapterOf = firstLine.map((t, i) => {
    if (i < 15) return "（目录）";
    const hit = titles.find(x => t === x || t.startsWith(x + " "));
    if (hit) cur = hit;
    return cur;
  });
  // 合并连续同名页
  const chapters = [];
  chapterOf.forEach((c, i) => {
    const last = chapters[chapters.length - 1];
    if (last && last.title === c) last.to = i + 1; else chapters.push({ title: c, from: i + 1, to: i + 1 });
  });
  // 清理旧文件
  for (const f of fs.readdirSync(path.join(out, "chapters"))) fs.unlinkSync(path.join(out, "chapters", f));
  const safe = t => t.replace(/[\\/:*?"<>|\s]+/g, "_").slice(0, 40);
  let tsv = "章节\t起始页\t结束页\t文件\n";
  chapters.forEach(ch => {
    const file = `${String(ch.from).padStart(4, "0")}_${safe(ch.title)}.txt`;
    let body = "";
    for (let p = ch.from; p <= ch.to; p++) {
      const text = pages[p - 1].replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
      body += `[p.${p}]\n${text}\n\n`;
    }
    fs.writeFileSync(path.join(out, "chapters", file), `# ${ch.title}（第 ${ch.from}-${ch.to} 页）\n\n${body}`);
    tsv += `${ch.title}\t${ch.from}\t${ch.to}\t${file}\n`;
  });
  fs.writeFileSync(path.join(out, "chapters.tsv"), tsv);
  fs.writeFileSync(path.join(out, "SOURCE.txt"), `来源：${path.resolve(pdf)}\n页数：${pages.length}\n生成时间：${new Date().toLocaleString()}\n`);
  console.log(`完成：${pages.length} 页，${chapters.length} 章 → ${out}`);
  process.exit(0);
}

if (cmd === "find") {
  if (!rest.length) { console.error("用法：node kotlin-docs.js find <关键字...> [--chapter 章节名片段] [--max 8]"); process.exit(2); }
  const dir = path.resolve(opt.dir || DEFAULT_DIR);
  const tsvFile = path.join(dir, "chapters.tsv");
  if (!fs.existsSync(tsvFile)) { console.error(`还没有切分好的文档：${dir}，先运行 build`); process.exit(1); }
  const max = +(opt.max || 8), ctx = +(opt.context || 120);
  const rows = fs.readFileSync(tsvFile, "utf8").trim().split(/\r?\n/).slice(1).map(l => { const [title, from, to, file] = l.split("\t"); return { title, from: +from, to: +to, file }; });
  const kws = rest.map(k => k.toLowerCase());
  let n = 0;
  for (const ch of rows) {
    if (opt.chapter && !ch.title.includes(opt.chapter)) continue;
    if (ch.title === "（目录）") continue;
    const text = fs.readFileSync(path.join(dir, "chapters", ch.file), "utf8");
    for (const part of text.split(/^\[p\.(\d+)\]$/m).reduce((a, x, i, arr) => (i % 2 ? a.push([+x, arr[i + 1]]) : 0, a), [])) {
      const [page, body] = part;
      const low = body.toLowerCase();
      if (!kws.every(k => low.includes(k))) continue;
      const at = low.indexOf(kws[0]);
      const snip = body.slice(Math.max(0, at - ctx / 2), at + ctx).replace(/\s+/g, " ").trim();
      console.log(`${ch.title} · 第 ${page} 页\n    …${snip}…`);
      if (++n >= max) { console.log(`（只显示前 ${max} 条，用 --max 调整，或用 --chapter 限定章节）`); process.exit(0); }
    }
  }
  if (!n) console.log("没有找到。");
  process.exit(0);
}

console.error("用法：node kotlin-docs.js build <pdf> | find <关键字...>");
process.exit(2);
