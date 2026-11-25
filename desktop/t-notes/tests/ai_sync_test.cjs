'use strict';
// AI records sync between two computers through an in-memory server that follows server.py's blob rules.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const zlib = require('node:zlib');
const {createAiSync, blobId, seal, pack, SLICE} = require('../client/ai-sync.cjs');

function fakeServer({blobs = true} = {}) {
  const store = new Map(), tokens = new Set(), calls = [];
  const limit = 32 * 1024 * 1024;
  const used = () => [...store.values()].reduce((sum, row) => sum + row.envelope.length, 0);
  async function request(method, url, body, token) {
    calls.push(method + ' ' + url.replace(/id=.*/, 'id=…'));
    if (method === 'POST' && url === '/v1/login') {
      if (body.name !== 'vault-name' || body.auth !== 'a'.repeat(64)) return {status: 401, data: {}};
      const value = crypto.randomUUID(); tokens.add(value); return {status: 200, data: {token: value}};
    }
    if (!url.startsWith('/v1/blobs') || !blobs) return {status: 404, data: {error: 'Not found'}};
    if (!tokens.has(token)) return {status: 401, data: {}};
    if (method === 'GET' && url === '/v1/blobs')
      return {status: 200, data: {items: [...store.entries()].map(([id, row]) => ({id, rev: row.rev, size: row.envelope.length, updated: 0})), used: used(), limit}};
    if (method === 'GET') {
      const id = url.split('id=')[1], row = store.get(id);
      return row ? {status: 200, data: {id, rev: row.rev, envelope: JSON.parse(row.envelope), updated: 0}} : {status: 404, data: {}};
    }
    if (method === 'PUT') {
      const decoded = Buffer.from(body.envelope.data, 'base64');
      assert.ok(decoded.length <= 160000, 'blob over the server limit');
      assert.ok(JSON.stringify(body).length <= 262144, 'request over the server body limit');
      assert.match(body.id, /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
      const row = store.get(body.id), encoded = JSON.stringify(body.envelope);
      if (row && row.envelope === encoded) return {status: 200, data: {id: body.id, rev: row.rev}};
      if ((!row && body.base !== 0) || (row && row.rev !== body.base)) return {status: 409, data: {}};
      const rev = (row ? row.rev : 0) + 1;
      store.set(body.id, {rev, envelope: encoded});
      return {status: 200, data: {id: body.id, rev}};
    }
    return {status: 404, data: {}};
  }
  return {request, store, calls};
}

const key = crypto.randomBytes(32), vault = crypto.randomUUID();
const credentials = async () => ({key, auth: 'a'.repeat(64), vault, name: 'vault-name'});
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'ai-sync-test-'));
const computer = name => {
  const root = path.join(temp, name);
  fs.mkdirSync(path.join(root, 'sessions'), {recursive: true});
  return root;
};
const archive = (root, session, text) => {
  const bytes = zlib.gzipSync(Buffer.from(JSON.stringify({Session: session, Records: [{Question: text}]})));
  fs.writeFileSync(path.join(root, 'sessions', session + '.json.gz'), bytes);
  return bytes;
};
const read = (root, session) => fs.readFileSync(path.join(root, 'sessions', session + '.json.gz'));
const status = root => JSON.parse(fs.readFileSync(path.join(root, 'sync-status.json'), 'utf8'));

(async () => {
  try {
    const server = fakeServer();
    const a = computer('a'), b = computer('b');
    const syncA = createAiSync({codex: null, root: a, request: server.request, credentials});
    const syncB = createAiSync({codex: null, root: b, request: server.request, credentials});

    // A large session needs several blobs: random text compresses little.
    const big = archive(a, 'session-big', crypto.randomBytes(400000).toString('base64'));
    const small = archive(a, 'session-small', '你好，帮我看看这个问题');
    assert.ok(big.length > 2 * SLICE);
    await syncA.sync();
    assert.equal(status(a).state, 'ok');
    assert.equal(status(a).uploaded, 2);
    assert.equal(server.store.size, Math.ceil(big.length / SLICE) + 1);
    // The server holds ciphertext only.
    const everything = [...server.store.values()].map(row => Buffer.from(JSON.parse(row.envelope).data, 'base64')).reduce((all, part) => Buffer.concat([all, part]), Buffer.alloc(0));
    assert.equal(everything.includes(small.subarray(10, 40)), false);
    assert.ok(status(a).stored > 0);

    await syncB.sync();
    assert.equal(status(b).downloaded, 2);
    assert.deepEqual(read(b, 'session-big'), big);
    assert.deepEqual(read(b, 'session-small'), small);

    // Nothing changed: no blob is fetched or written again, on either computer.
    let before = server.calls.length;
    await syncB.sync();
    await syncA.sync();
    assert.deepEqual(server.calls.slice(before), ['GET /v1/blobs', 'GET /v1/blobs']);
    assert.equal(status(b).downloaded, 0);

    // The big session shrinks to one part: the parts left over are emptied, and B gets the new version.
    const shrunk = archive(a, 'session-big', 'short now');
    await syncA.sync();
    const emptied = [...server.store.values()].filter(row => Buffer.from(JSON.parse(row.envelope).data, 'base64').length < 200);
    assert.ok(emptied.length >= 2);
    await syncB.sync();
    assert.deepEqual(read(b, 'session-big'), shrunk);
    assert.equal(status(b).downloaded, 1);

    // A copy changed on B and not synced yet is kept, then uploaded; A receives it.
    archive(a, 'session-small', 'A version');
    await syncA.sync();
    const mine = archive(b, 'session-small', 'B version, written later');
    await syncB.sync();
    assert.deepEqual(read(b, 'session-small'), mine);
    await syncA.sync();
    assert.deepEqual(read(a, 'session-small'), mine);

    // A blob that names a path outside the folder, or that is not sealed for its id, is ignored.
    const evil = blobId(key, 'evil', 0), payload = zlib.gzipSync(Buffer.from('{}'));
    const header = {format: 1, session: '../../outside', part: 0, parts: 1, hash: crypto.createHash('sha256').update(payload).digest('hex'), size: payload.length};
    server.store.set(evil, {rev: 1, envelope: JSON.stringify(seal(key, vault, evil, pack(header, payload)))});
    const moved = crypto.randomUUID();
    server.store.set(moved, {rev: 1, envelope: server.store.get(blobId(key, 'session-small', 0)).envelope});
    await syncB.sync();
    assert.equal(status(b).state, 'ok');
    assert.equal(fs.existsSync(path.join(temp, 'outside.json.gz')), false);
    assert.deepEqual(fs.readdirSync(path.join(b, 'sessions')).sort(), ['session-big.json.gz', 'session-small.json.gz']);
    before = server.calls.length;
    await syncB.sync();
    assert.deepEqual(server.calls.slice(before), ['GET /v1/blobs']);

    // A half-written file (not valid gzip yet) waits for the next sync.
    fs.writeFileSync(path.join(a, 'sessions', 'session-new.json.gz'), Buffer.from([0x1f, 0x8b, 8, 0]));
    await syncA.sync();
    assert.equal(status(a).uploaded, 0);

    // An old server without blobs, no remembered login, a login that no longer matches the vault.
    const old = computer('old');
    archive(old, 'session-x', 'x');
    await createAiSync({codex: null, root: old, request: fakeServer({blobs: false}).request, credentials}).sync();
    assert.equal(status(old).state, 'off');
    assert.match(status(old).message, /还没升级/);
    await createAiSync({codex: null, root: old, request: server.request, credentials, unavailable: () => '随手记没有记住登录'}).sync();
    assert.equal(status(old).message, '随手记没有记住登录');
    await createAiSync({codex: null, root: old, request: server.request, credentials: async () => null}).sync();
    assert.equal(status(old).state, 'off');
    // The server cannot be reached.
    await createAiSync({codex: null, root: old, request: async () => { throw Object.assign(Error('down'), {code: 'ECONNREFUSED'}); }, credentials}).sync();
    assert.equal(status(old).state, 'error');
    assert.match(status(old).message, /无法连接/);
    console.log('PASS: AI records sync (compressed, encrypted, split, conflicts, unsafe blobs, old server).');
  } finally {
    fs.rmSync(temp, {recursive: true, force: true});
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
