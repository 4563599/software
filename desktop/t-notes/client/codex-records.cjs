'use strict';
// Codex conversations for the AI records window (dev-tools\AiRecords.cs.txt). Codex (the desktop app and CLI)
// keeps its conversations in SQLite under ~/.codex: the threads in state_<n>.sqlite, their messages in
// thread_history_<n>.sqlite. Each conversation the user started is written as <records>\sessions\codex-<id>.json.gz
// in the same format as the Claude archives, so the window reads, searches and syncs both alike.
// The databases are only read. Run by the notes backend before each sync, and by the window when it loads:
//   node --no-warnings codex-records.cjs export <records>\sessions
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const zlib = require('node:zlib');

function codexHome(env = process.env) {
  return env.CODEX_HOME && path.isAbsolute(env.CODEX_HOME) ? env.CODEX_HOME : path.join(os.homedir(), '.codex');
}

// state_5.sqlite today; a newer Codex may number it higher.
function latest(home, pattern) {
  let best = null, number = -1;
  try {
    for (const name of fs.readdirSync(home)) {
      const match = pattern.exec(name);
      if (match && Number(match[1]) > number) { number = Number(match[1]); best = path.join(home, name); }
    }
  } catch {}
  return best;
}

function open(file) {
  const {DatabaseSync} = require('node:sqlite');
  const db = new DatabaseSync(file, {readOnly: true});
  db.exec('PRAGMA busy_timeout=3000');
  return db;
}

// The repository folder the conversation ran in, as for Claude ("software", "Octopus").
function projectName(cwd) {
  if (!cwd) return 'Codex';
  if (/scratch-workspaces/i.test(cwd)) return '临时会话';
  try {
    if (fs.existsSync(cwd)) {
      for (let dir = path.resolve(cwd); ;) {
        if (fs.existsSync(path.join(dir, '.git'))) return path.basename(dir);
        const up = path.dirname(dir);
        if (up === dir) break;
        dir = up;
      }
      return path.basename(path.resolve(cwd)) || cwd;
    }
  } catch {}
  return path.basename(cwd.replace(/[\\/]+$/, '')) || cwd;
}

// Raised when the way messages are cleaned changes, so every conversation is written again.
const FORMAT = 3;

// The project each conversation sits under in the Codex sidebar. The app keeps the assignment in
// .codex-global-state.json ("thread-project-assignments", by older project ids) and the names in the projects table;
// a conversation can have moved to another folder since (a worktree), so its folder is not a reliable guide.
function sidebarProjects(home, state) {
  let global;
  try { global = JSON.parse(fs.readFileSync(path.join(home, '.codex-global-state.json'), 'utf8')); } catch { return new Map(); }
  const assignments = global['thread-project-assignments'] || {}, local = global['local-projects'] || {};
  const current = Object.assign({}, ...Object.values(global['app-server-project-id-by-legacy-project-id-by-host'] || {}).filter(map => map && typeof map === 'object'));
  let named = new Map();
  try { named = new Map(state.prepare('SELECT id, name FROM projects').all().map(row => [row.id, row.name])); } catch {}
  const projects = new Map();
  for (const [thread, assignment] of Object.entries(assignments)) {
    const id = assignment && assignment.projectId;
    let name = named.get(current[id]) || named.get(id) || (local[id] && local[id].name);
    if (typeof name !== 'string' || !name.trim()) continue;
    name = name.trim();
    // Some projects are named by their full path; the last folder reads better in the list.
    if (/^[A-Za-z]:[\\/]|^\\\\/.test(name)) name = path.basename(name.replace(/[\\/]+$/, '')) || name;
    projects.set(thread, name);
  }
  return projects;
}

// .NET ticks of the local wall-clock time, as the Claude archives store them.
const ticks = ms => Math.round((ms - new Date(ms).getTimezoneOffset() * 60000) * 10000 + 621355968000000000);

// The composer stores some characters as HTML references (有 as &#x6709;, a space as &#x20;).
function decodeEntities(text) {
  const named = {amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' '};
  return text.replace(/&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|[a-z]+);/g, (whole, code) => {
    if (code[0] !== '#') return Object.prototype.hasOwnProperty.call(named, code) ? named[code] : whole;
    const value = code[1] === 'x' ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
    return value > 0 && value <= 0x10ffff ? String.fromCodePoint(value) : whole;
  });
}

// A message with attachments arrives as "# Files mentioned by the user:", one "## name: path" line per file (with
// notes such as "Image attachment: true"), then "## My request:" or "## My request for Codex:" and what was typed.
// Pasted pictures are counted as pictures; other files are named.
function splitAttachments(text) {
  const marker = /^\s*# Files mentioned by the user:\s*\n([\s\S]*?)\n## My request(?: for Codex)?:[ \t]*\r?\n?/.exec(text);
  if (!marker) return {text, files: []};
  const files = [...marker[1].matchAll(/^## (.+?):\s/gm)].map(match => match[1].trim()).filter(name => !/^codex-clipboard-/.test(name));
  return {text: text.slice(marker[0].length), files};
}

// Text the app adds around what was typed. Returns {text, automated}.
function cleanQuestion(raw) {
  const attached = splitAttachments(raw);
  let text = decodeEntities(attached.text);
  if (attached.files.length) text += '\n\n[附件：' + attached.files.join('、') + ']';
  // An automation's run: its instructions stand in for the question.
  const beat = /^\s*<heartbeat>[\s\S]*?<instructions>([\s\S]*?)<\/instructions>/.exec(text);
  if (beat) return {text: '【自动化任务】' + beat[1].trim(), automated: true};
  if (/^\s*<no retained transcript delta entries>\s*$/.test(text)) return {text: '', automated: false};
  // The answer to a question Codex asked.
  text = text.replace(/<send_user_message_question_reply>\s*([\s\S]*?)\s*<\/send_user_message_question_reply>/g, '$1');
  // The page open in the in-app browser, sent along with the message.
  text = text.replace(/<in-app-browser-context\b[^>]*>[\s\S]*?<\/in-app-browser-context>\s*/g, '【附带了浏览器页面内容】\n');
  // file:///D:/%E5%8D… links shown as the readable path.
  text = text.replace(/file:\/\/\/[^\s<>"]+/g, link => { try { return decodeURIComponent(link); } catch { return link; } });
  return {text: text.trim(), automated: false};
}

function messageText(item) {
  const texts = [], content = Array.isArray(item.content) ? item.content : [];
  let pictures = 0;
  for (const part of content) {
    if (part?.type === 'text' && typeof part.text === 'string' && part.text.trim()) texts.push(part.text);
    else if (part?.type === 'localImage' || part?.type === 'image') pictures++;
  }
  const cleaned = cleanQuestion(texts.join('\n\n'));
  if (pictures) cleaned.text += (cleaned.text ? '\n\n' : '') + '[附图 ' + pictures + ' 张]';
  return cleaned;
}

// Rounds as the Claude parser makes them: each typed message starts one; Codex's final answer of the round is the
// answer, its other messages ("commentary", written while working) are the process.
function rounds(items, fallbackMs) {
  const records = [];
  let current = null;
  const close = () => {
    if (!current) return;
    const texts = current.texts;
    let at = -1;
    for (let i = texts.length - 1; i >= 0; i--) if (texts[i].final) { at = i; break; }
    if (at < 0) at = texts.length - 1;
    records.push({
      Question: current.question,
      Process: texts.filter((_, i) => i !== at).map(t => t.text),
      Answer: at >= 0 ? texts[at].text : '',
      QuestionTicks: current.questionTicks,
      AnswerTicks: current.answerTicks,
      Handed: current.automated,
    });
    current = null;
  };
  for (const row of items) {
    let item;
    try { item = JSON.parse(row.item_json); } catch { continue; }
    const ms = row.created_at_ms || row.completed_at_ms || row.started_at_ms || fallbackMs;
    if (row.item_type === 'userMessage') {
      const {text, automated} = messageText(item);
      if (!text) continue;
      close();
      current = {question: text, automated, questionTicks: ticks(ms), answerTicks: 0, texts: []};
    } else if (row.item_type === 'agentMessage' && current) {
      const text = typeof item.text === 'string' ? item.text.trim() : '';
      if (!text) continue;
      current.texts.push({text, final: item.phase === 'final_answer'});
      current.answerTicks = ticks(row.completed_at_ms || row.created_at_ms || ms);
    }
  }
  close();
  return records;
}

function writeAtomic(file, bytes) {
  const temp = file + '.' + process.pid + '.tmp';
  fs.writeFileSync(temp, bytes);
  try { fs.renameSync(temp, file); } catch (e) { try { fs.unlinkSync(temp); } catch {} throw e; }
}

// Writes the conversations that changed since the last export. Returns how many archives were written.
function exportCodex({sessionsDir, home = codexHome(), machine = process.env.COMPUTERNAME || os.hostname()}) {
  const stateFile = latest(home, /^state_(\d+)\.sqlite$/), historyFile = latest(home, /^thread_history_(\d+)\.sqlite$/);
  if (!stateFile || !historyFile) return 0;
  fs.mkdirSync(sessionsDir, {recursive: true});
  const memoPath = path.join(path.dirname(sessionsDir), 'codex-export.json');
  let memo = {};
  try { memo = JSON.parse(fs.readFileSync(memoPath, 'utf8')).threads || {}; } catch {}
  let state, history, written = 0;
  try {
    state = open(stateFile);
    history = open(historyFile);
    // Only conversations the user started: not sub-agents, approval reviews and the like.
    const threads = state.prepare("SELECT id, cwd, title, name, created_at_ms FROM threads WHERE thread_source IN ('user','voice_chat')").all();
    // How far each conversation's messages have been recorded: a cheap way to see which ones changed (counting the
    // messages themselves would read the whole 200 MB database).
    let signatures;
    try {
      signatures = new Map(history.prepare('SELECT thread_id, next_rollout_ordinal AS o, next_rollout_byte_offset AS b FROM thread_history_projection_state')
        .all().map(row => [row.thread_id, row.o + ':' + row.b]));
    } catch {
      signatures = new Map(history.prepare("SELECT thread_id, COUNT(*) AS n, MAX(rollout_ordinal) AS o FROM thread_items GROUP BY thread_id")
        .all().map(row => [row.thread_id, row.n + ':' + row.o]));
    }
    const sidebar = sidebarProjects(home, state);
    const select = history.prepare("SELECT item_type, item_json, created_at_ms, started_at_ms, completed_at_ms FROM thread_items WHERE thread_id=? AND item_type IN ('userMessage','agentMessage') ORDER BY rollout_ordinal");
    for (const thread of threads) {
      if (!/^[A-Za-z0-9-]{8,80}$/.test(thread.id) || !signatures.has(thread.id)) continue;
      const title = thread.name || thread.title || '';
      const signature = FORMAT + ':' + signatures.get(thread.id) + ':' + title + ':' + (thread.cwd || '') + ':' + (sidebar.get(thread.id) || '');
      const file = path.join(sessionsDir, 'codex-' + thread.id + '.json.gz');
      if (memo[thread.id] === signature && fs.existsSync(file)) continue;
      const records = rounds(select.all(thread.id), thread.created_at_ms || Date.now());
      if (records.length) {
        // Codex stores folders as \\?\D:\...; shown without that prefix.
        const cwd = (thread.cwd || '').replace(/^\\\\\?\\/, '');
        const archive = {Session: 'codex-' + thread.id, Project: sidebar.get(thread.id) || projectName(cwd), Title: title, Cwd: cwd,
          Transcript: '', Machine: machine, Source: 'Codex', Length: 0, Written: 0, Records: records};
        writeAtomic(file, zlib.gzipSync(Buffer.from(JSON.stringify(archive), 'utf8'), {level: 9}));
        written++;
      }
      memo[thread.id] = signature;
    }
  } finally {
    try { state?.close(); } catch {}
    try { history?.close(); } catch {}
  }
  writeAtomic(memoPath, JSON.stringify({version: 1, threads: memo}));
  return written;
}

module.exports = {exportCodex, cleanQuestion, rounds, projectName, ticks};

if (require.main === module) {
  const [command, sessionsDir] = process.argv.slice(2);
  if (command !== 'export' || !sessionsDir || !path.isAbsolute(sessionsDir)) { console.error('usage: codex-records.cjs export <absolute sessions folder>'); process.exit(2); }
  try { console.log(String(exportCodex({sessionsDir}))); }
  catch (e) { console.error('Codex export failed: ' + (e.code || e.message)); process.exit(1); }
}
