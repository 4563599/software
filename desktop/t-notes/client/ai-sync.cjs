'use strict';
// AI conversation records sync. dev-tools\AiRecords.cs.txt keeps one gzip file per Claude session in
// <records>\sessions; this module copies them between computers through the notes server's blob store,
// encrypted with the vault key, so the server only ever sees ciphertext.
// Blobs are kept apart from the notes records on purpose: the notes window lists every record on each
// sync, while the blob listing carries only ids, revisions and sizes, and a session is downloaded only
// after it changed.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const {spawn} = require('node:child_process');
const {exportCodex} = require('./codex-records.cjs');

// A blob's plaintext stays under the server's 160000-byte ciphertext limit (the tag adds 16 bytes).
const SLICE = 148000;
const SESSION = /^[A-Za-z0-9_-]{1,100}$/;
const MAX_ARCHIVE = 256 * 1024 * 1024;

// The same rule as ChatArchive.RecordsRoot in dev-tools\AiRecords.cs.txt.
function recordsRoot(env = process.env) {
  const custom = env.TNOTES_AI_RECORDS;
  if (custom && path.isAbsolute(custom)) return custom;
  if (process.platform === 'win32' && fs.existsSync('E:\\')) return 'E:\\AIRecords';
  return path.join(env.LOCALAPPDATA || os.homedir(), 'TNotes', 'ai-records');
}

const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');

// Ids come from the vault key, so the server cannot tell which session a blob belongs to.
function blobId(key, session, part) {
  const digest = crypto.createHmac('sha256', key).update('tnotes-ai-v1:blob:' + session + ':' + part).digest();
  digest[6] = (digest[6] & 0x0f) | 0x40;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = digest.subarray(0, 16).toString('hex');
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
}

// AES-256-GCM laid out as Web Crypto does (ciphertext then tag). The additional data binds a blob to
// its vault and id, and differs from the notes records' 'tnotes-v1:' so one can never pass for the other.
function seal(key, vault, id, plain) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from('tnotes-ai-v1:' + vault + ':' + id));
  const data = Buffer.concat([cipher.update(plain), cipher.final(), cipher.getAuthTag()]);
  return {iv: iv.toString('base64'), data: data.toString('base64')};
}

function unseal(key, vault, id, envelope) {
  const iv = Buffer.from(envelope.iv, 'base64'), all = Buffer.from(envelope.data, 'base64');
  if (iv.length !== 12 || all.length < 16) throw Error('Invalid blob');
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAAD(Buffer.from('tnotes-ai-v1:' + vault + ':' + id));
  decipher.setAuthTag(all.subarray(all.length - 16));
  return Buffer.concat([decipher.update(all.subarray(0, all.length - 16)), decipher.final()]);
}

// Plaintext: 4-byte header length, header JSON, then this part's slice of the gzip file.
function pack(header, slice) {
  const head = Buffer.from(JSON.stringify(header), 'utf8'), size = Buffer.alloc(4);
  size.writeUInt32BE(head.length);
  return Buffer.concat([size, head, slice]);
}

function unpack(plain) {
  const length = plain.length >= 4 ? plain.readUInt32BE(0) : -1;
  if (length < 2 || length > 4096 || 4 + length > plain.length) throw Error('Invalid blob');
  return {header: JSON.parse(plain.subarray(4, 4 + length).toString('utf8')), slice: plain.subarray(4 + length)};
}

const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

// The AI records window may be reading the file for a moment; Windows then refuses the rename.
async function replaceFile(file, bytes) {
  fs.mkdirSync(path.dirname(file), {recursive: true});
  const temp = file + '.' + process.pid + '.tmp';
  fs.writeFileSync(temp, bytes);
  for (let attempt = 0; ; attempt++) {
    try { fs.renameSync(temp, file); return; }
    catch (e) {
      if (attempt >= 8 || !['EPERM', 'EACCES', 'EBUSY'].includes(e.code)) { try { fs.unlinkSync(temp); } catch {} throw e; }
      await delay(150);
    }
  }
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

class SyncStop extends Error {
  constructor(state, message) { super(message); this.state = state; }
}

// request(method, path, body, token) -> {status, data}; it rejects only when the server cannot be reached.
// unavailable() -> a reason not to sync now, or null. credentials() -> {key, auth, vault, name} or null.
// codex(sessionsDir) -> archives written from Codex's own records (codex-records.cjs); pass null to skip.
function createAiSync({root = recordsRoot(), request, unavailable = () => null, credentials, archiver = null, now = () => new Date(),
  codex = sessionsDir => exportCodex({sessionsDir})}) {
  const sessionsDir = path.join(root, 'sessions');
  const statePath = path.join(root, 'sync-state.json'), statusPath = path.join(root, 'sync-status.json');
  let token = null, running = null, queued = false, retryTimer = null;

  async function writeStatus(fields) {
    const previous = readJson(statusPath) || {};
    const time = now().toISOString();
    const value = {updated: time, uploaded: 0, downloaded: 0, codex: exported, ...fields,
      lastSuccess: fields.state === 'ok' ? time : previous.lastSuccess || null};
    await replaceFile(statusPath, JSON.stringify(value));
    return value;
  }

  let exported = 0;
  async function runOnce() {
    fs.mkdirSync(sessionsDir, {recursive: true});
    // Codex conversations become archives first, whether or not they can be synced; the window reloads
    // when the status says some were written.
    exported = 0;
    if (codex) { try { exported = codex(sessionsDir); } catch {} }
    const reason = unavailable();
    if (reason) { token = null; return writeStatus({state: 'off', message: reason}); }
    let state = readJson(statePath);
    if (!state || state.version !== 1) state = {version: 1, vault: null, files: {}, seen: {}};
    const save = () => replaceFile(statePath, JSON.stringify(state));
    let creds = null;
    async function need() {
      if (creds) return creds;
      creds = await credentials();
      if (!creds) throw new SyncStop('off', '随手记的登录记忆和资料库不一致，请重新登录随手记');
      // Another vault: what this computer knew about the server no longer applies.
      if (state.vault !== creds.vault) state = {version: 1, vault: creds.vault, files: {}, seen: {}};
      return creds;
    }
    async function api(method, url, body) {
      for (let attempt = 0; attempt < 2; attempt++) {
        if (!token) {
          const {name, auth} = await need();
          const login = await request('POST', '/v1/login', {name, auth});
          if (login.status !== 200) throw failure(login);
          token = login.data.token;
        }
        const res = await request(method, url, body, token);
        if (res.status === 401 && attempt === 0) { token = null; continue; }
        if (res.status === 429) throw new SyncStop('busy', '服务器繁忙，稍后自动继续同步');
        return res;
      }
    }

    // 1. Sessions that changed here since the last sync.
    const changed = [];
    for (const name of fs.readdirSync(sessionsDir)) {
      if (!name.endsWith('.json.gz')) continue;
      const session = name.slice(0, -'.json.gz'.length);
      if (!SESSION.test(session)) continue;
      const file = path.join(sessionsDir, name);
      let info;
      try { info = fs.statSync(file); } catch { continue; }
      const known = state.files[session];
      if (known && known.size === info.size && known.mtime === info.mtimeMs) continue;
      const bytes = fs.readFileSync(file);
      const hash = sha256(bytes);
      if (known && known.hash === hash) { known.size = info.size; known.mtime = info.mtimeMs; continue; }
      // A file still being written is picked up next time.
      try { zlib.gunzipSync(bytes, {maxOutputLength: MAX_ARCHIVE}); } catch { continue; }
      changed.push({session, bytes, hash, size: info.size, mtime: info.mtimeMs});
    }

    const listing = await api('GET', '/v1/blobs');
    if (listing.status === 404) throw new SyncStop('off', '同步服务器还没升级，AI 记录暂时只保存在本机');
    if (listing.status !== 200) throw failure(listing);
    const remote = new Map(listing.data.items.map(item => [item.id, {id: item.id, rev: item.rev}]));

    async function put(id, plain) {
      const {key, vault} = await need();
      for (let attempt = 0; attempt < 2; attempt++) {
        const base = remote.get(id)?.rev || 0;
        const res = await api('PUT', '/v1/blobs', {id, base, envelope: seal(key, vault, id, plain)});
        if (res.status === 200) { remote.set(id, {id, rev: res.data.rev}); return res.data.rev; }
        // Written elsewhere since the listing: write over it at its current revision.
        if (res.status === 409 && attempt === 0) {
          const fresh = await api('GET', '/v1/blobs?id=' + id);
          remote.set(id, {id, rev: fresh.status === 200 ? fresh.data.rev : 0});
          continue;
        }
        throw failure(res);
      }
    }

    // 2. Upload: each session as one or more parts, each part one encrypted blob. A first upload can take minutes,
    // so the window says it is under way.
    let uploaded = 0;
    if (changed.length) await writeStatus({state: 'running', message: '正在上传 ' + changed.length + ' 个会话到服务器…'});
    for (const item of changed) {
      const {key} = await need();
      const slices = [];
      for (let at = 0; at === 0 || at < item.bytes.length; at += SLICE) slices.push(item.bytes.subarray(at, at + SLICE));
      const parts = [];
      for (let part = 0; part < slices.length; part++) {
        const id = blobId(key, item.session, part);
        parts.push(id);
        state.seen[id] = await put(id, pack({format: 1, session: item.session, part, parts: slices.length, hash: item.hash, size: item.bytes.length}, slices[part]));
      }
      // Parts left from a longer earlier version are emptied so they stop taking space.
      const earlier = state.files[item.session]?.parts || [];
      for (let part = slices.length; part < earlier.length; part++) {
        state.seen[earlier[part]] = await put(earlier[part], pack({format: 1, session: item.session, part, parts: 0}, Buffer.alloc(0)));
      }
      state.files[item.session] = {size: item.size, mtime: item.mtime, hash: item.hash, parts};
      uploaded++;
      await save();
    }

    // 3. Download what other computers changed: all parts of a version first, then the file is written.
    let downloaded = 0, busy = false;
    const pending = [...remote.values()].filter(item => state.seen[item.id] !== item.rev);
    if (pending.length) {
      const {key, vault} = await need();
      const groups = new Map();
      for (const item of pending) {
        let res;
        try { res = await api('GET', '/v1/blobs?id=' + item.id); }
        catch (e) { if (e.state === 'busy') { busy = true; break; } throw e; }
        if (res.status === 404) continue;
        if (res.status !== 200) throw failure(res);
        let blob;
        try { blob = unpack(unseal(key, vault, item.id, res.data.envelope)); }
        catch { state.seen[item.id] = res.data.rev; continue; }
        const {header} = blob;
        const valid = header.format === 1 && typeof header.session === 'string' && SESSION.test(header.session) &&
          Number.isInteger(header.parts) && header.parts >= 0 && Number.isInteger(header.part) && header.part >= 0;
        if (!valid || header.parts === 0 || header.part >= header.parts || !/^[a-f0-9]{64}$/.test(header.hash || '')) { state.seen[item.id] = res.data.rev; continue; }
        const label = header.session + ':' + header.hash;
        const group = groups.get(label) || {header, slices: [], revs: new Map()};
        group.slices[header.part] = blob.slice;
        group.revs.set(item.id, res.data.rev);
        groups.set(label, group);
      }
      for (const group of groups.values()) {
        const {session, parts, hash, size} = group.header;
        // Missing parts are still being uploaded by the other computer: this version is tried again next time.
        if (group.slices.filter(Boolean).length !== parts) continue;
        const bytes = Buffer.concat(group.slices);
        if (bytes.length !== size || sha256(bytes) !== hash) continue;
        try { zlib.gunzipSync(bytes, {maxOutputLength: MAX_ARCHIVE}); } catch { for (const [id, rev] of group.revs) state.seen[id] = rev; continue; }
        const file = path.join(sessionsDir, session + '.json.gz');
        let local = null;
        try { local = sha256(fs.readFileSync(file)); } catch {}
        // A copy changed on this computer and not uploaded yet stays; it is uploaded on the next sync.
        const keepLocal = local !== null && local !== hash && state.files[session]?.hash !== local;
        if (local !== hash && !keepLocal) { await replaceFile(file, bytes); downloaded++; }
        if (!keepLocal) {
          const info = fs.statSync(file);
          state.files[session] = {size: info.size, mtime: info.mtimeMs, hash, parts: Array.from({length: parts}, (_, part) => blobId(key, session, part))};
        }
        for (const [id, rev] of group.revs) state.seen[id] = rev;
      }
      await save();
    }

    let stored = listing.data.used, limit = listing.data.limit;
    if (uploaded) {
      const after = await api('GET', '/v1/blobs');
      if (after.status === 200) { stored = after.data.used; limit = after.data.limit; }
    }
    if (busy) { clearTimeout(retryTimer); retryTimer = setTimeout(sync, 65000); }
    return writeStatus({state: 'ok', message: busy ? '已同步一部分，稍后自动继续' : '已同步到服务器', uploaded, downloaded, stored, limit});
  }

  function failure(res) {
    if (res.status === 413) return new SyncStop('error', '服务器上 AI 记录的空间已满，新内容暂时只保存在本机');
    if (res.status === 401) return new SyncStop('error', '同步服务器拒绝了登录，请重新登录随手记');
    return new SyncStop('error', '同步失败（服务器返回 ' + res.status + '），稍后自动重试');
  }

  function sync() {
    if (running) { queued = true; return running; }
    running = runOnce().catch(async e => {
      const state = e instanceof SyncStop ? (e.state === 'busy' ? 'error' : e.state) : 'error';
      const message = e instanceof SyncStop ? e.message : '同步服务器暂时无法连接，稍后自动重试';
      try { return await writeStatus({state, message}); } catch { return null; }
    }).finally(() => {
      running = null;
      if (queued) { queued = false; void sync(); }
    });
    return running;
  }

  // Copies new conversations out of Claude's transcripts (ai-records.ps1 -Archive) when they changed,
  // so rounds are kept and synced even if the records window is not opened for a while.
  let archivedAt = 0, archiving = false;
  function newestTranscript() {
    const projects = path.join(os.homedir(), '.claude', 'projects');
    let newest = 0;
    try {
      for (const folder of fs.readdirSync(projects, {withFileTypes: true})) {
        if (!folder.isDirectory()) continue;
        for (const name of fs.readdirSync(path.join(projects, folder.name))) {
          if (!name.endsWith('.jsonl')) continue;
          try { newest = Math.max(newest, fs.statSync(path.join(projects, folder.name, name)).mtimeMs); } catch {}
        }
      }
    } catch {}
    return newest;
  }
  function archive() {
    if (!archiver || archiving || !fs.existsSync(archiver)) return;
    const newest = newestTranscript();
    if (!newest || newest <= archivedAt) return;
    archiving = true;
    const executable = path.join(process.env.WINDIR || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
    // Not detached: Windows PowerShell started detached without a console exits without running the script.
    const child = spawn(executable, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', archiver, '-Archive'], {windowsHide: true, stdio: 'ignore'});
    const timer = setTimeout(() => child.kill(), 5 * 60 * 1000);
    const done = ok => { clearTimeout(timer); archiving = false; if (ok) archivedAt = newest; };
    child.on('error', () => done(false));
    child.on('close', code => done(code === 0));
  }

  function start() {
    let timer = null;
    const soon = () => { clearTimeout(timer); timer = setTimeout(sync, 4000); };
    try {
      fs.mkdirSync(sessionsDir, {recursive: true});
      // The records window writes sync-request to ask for a sync; new or changed session files start one too.
      fs.watch(sessionsDir, soon).on('error', () => {});
      fs.watch(root, (event, name) => { if (name === 'sync-request') soon(); }).on('error', () => {});
    } catch {}
    setTimeout(sync, 20000);
    setInterval(sync, 15 * 60 * 1000);
    setTimeout(archive, 60000);
    setInterval(archive, 30 * 60 * 1000);
  }

  return {sync, start, archive, root};
}

module.exports = {createAiSync, recordsRoot, blobId, seal, unseal, pack, unpack, SLICE};
