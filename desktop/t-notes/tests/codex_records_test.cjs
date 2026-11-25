'use strict';
// Codex conversations exported for the AI records window, from databases shaped like Codex's own.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const {DatabaseSync} = require('node:sqlite');
const {exportCodex, cleanQuestion, ticks} = require('../client/codex-records.cjs');
const {createAiSync} = require('../client/ai-sync.cjs');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-records-test-'));
try {
  const home = path.join(temp, 'codex'), repo = path.join(temp, 'my-repo'), sessions = path.join(temp, 'records', 'sessions');
  fs.mkdirSync(home);
  fs.mkdirSync(path.join(repo, '.git'), {recursive: true});
  fs.mkdirSync(path.join(repo, 'app'));
  const state = new DatabaseSync(path.join(home, 'state_5.sqlite'));
  state.exec('CREATE TABLE threads (id TEXT, cwd TEXT, title TEXT, name TEXT, created_at_ms INTEGER, thread_source TEXT)');
  const history = new DatabaseSync(path.join(home, 'thread_history_1.sqlite'));
  history.exec('CREATE TABLE thread_items (thread_id TEXT, item_type TEXT, item_json TEXT, created_at_ms INTEGER, started_at_ms INTEGER, completed_at_ms INTEGER, rollout_ordinal INTEGER, updated_at_ordinal INTEGER)');
  history.exec('CREATE TABLE thread_history_projection_state (thread_id TEXT, next_rollout_ordinal INTEGER, next_rollout_byte_offset INTEGER)');
  const thread = state.prepare('INSERT INTO threads VALUES (?,?,?,?,?,?)');
  thread.run('0001-user-thread', '\\\\?\\' + path.join(repo, 'app'), 'Fix the login page', null, 1790000000000, 'user');
  thread.run('0002-review', repo, 'review', null, 1790000000000, 'guardian_review');
  let ordinal = 0;
  const item = history.prepare('INSERT INTO thread_items VALUES (?,?,?,?,?,?,?,?)');
  const add = (id, type, json, ms) => item.run(id, type, JSON.stringify(json), ms, null, ms, ++ordinal, ordinal);
  const user = text => ({type: 'userMessage', content: [{type: 'text', text, text_elements: []}]});
  const agent = (text, phase) => ({type: 'agentMessage', text, phase});
  const t0 = 1790000000000;
  add('0001-user-thread', 'userMessage', {type: 'userMessage', content: [{type: 'text', text: '<in-app-browser-context source="page">page text</in-app-browser-context>\nwhy is this red?'}, {type: 'localImage', path: 'x.png'}]}, t0);
  add('0001-user-thread', 'agentMessage', agent('Looking at the styles.', 'commentary'), t0 + 1000);
  add('0001-user-thread', 'commentaryOther', {}, t0 + 1500);
  add('0001-user-thread', 'agentMessage', agent('The border uses the error colour.', 'final_answer'), t0 + 2000);
  add('0001-user-thread', 'userMessage', user('<send_user_message_question_reply>use blue</send_user_message_question_reply>'), t0 + 3000);
  add('0001-user-thread', 'agentMessage', agent('Changed to blue.', 'final_answer'), t0 + 4000);
  add('0001-user-thread', 'userMessage', user('<heartbeat><automation_id>a1</automation_id><current_time_iso>now</current_time_iso><instructions>check the build</instructions></heartbeat>'), t0 + 5000);
  add('0002-review', 'userMessage', user('approve this?'), t0);
  history.exec("INSERT INTO thread_history_projection_state VALUES ('0001-user-thread', 7, 700), ('0002-review', 1, 100)");
  // The Codex sidebar puts the conversation under its own project (named in the projects table, assigned by an
  // older id in the app's state file), whatever folder it ended up in.
  state.exec("CREATE TABLE projects (id TEXT, name TEXT); INSERT INTO projects VALUES ('new-id', 'Sidebar Name')");
  fs.writeFileSync(path.join(home, '.codex-global-state.json'), JSON.stringify({
    'thread-project-assignments': {'0001-user-thread': {projectKind: 'local', projectId: 'old-id'}},
    'local-projects': {'old-id': {id: 'old-id', name: 'old name'}},
    'app-server-project-id-by-legacy-project-id-by-host': {'local:x': {'old-id': 'new-id'}},
  }));

  assert.equal(exportCodex({sessionsDir: sessions, home, machine: 'PC-1'}), 1);
  assert.deepEqual(fs.readdirSync(sessions), ['codex-0001-user-thread.json.gz']);
  const archive = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(sessions, 'codex-0001-user-thread.json.gz'))));
  assert.equal(archive.Source, 'Codex');
  assert.equal(archive.Session, 'codex-0001-user-thread');
  assert.equal(archive.Project, 'Sidebar Name');
  assert.equal(archive.Cwd, path.join(repo, 'app'));
  assert.equal(archive.Machine, 'PC-1');
  assert.equal(archive.Title, 'Fix the login page');
  assert.equal(archive.Records.length, 3);
  const [first, second, third] = archive.Records;
  assert.equal(first.Question, '【附带了浏览器页面内容】\nwhy is this red?\n\n[附图 1 张]');
  assert.deepEqual(first.Process, ['Looking at the styles.']);
  assert.equal(first.Answer, 'The border uses the error colour.');
  assert.equal(first.QuestionTicks, ticks(t0));
  assert.equal(first.AnswerTicks, ticks(t0 + 2000));
  assert.equal(second.Question, 'use blue');
  assert.equal(second.Answer, 'Changed to blue.');
  assert.equal(third.Question, '【自动化任务】check the build');
  assert.equal(third.Handed, true);
  assert.equal(third.Answer, '');
  // .NET ticks of the local clock: 1970-01-01 local midnight is 621355968000000000.
  const midnight = new Date(1970, 0, 2).getTime();
  assert.equal(ticks(midnight), 621355968000000000 + 864000000000);

  // Unchanged: nothing written. More messages: written again.
  assert.equal(exportCodex({sessionsDir: sessions, home, machine: 'PC-1'}), 0);
  add('0001-user-thread', 'agentMessage', agent('Build is green.', 'final_answer'), t0 + 6000);
  history.exec("UPDATE thread_history_projection_state SET next_rollout_ordinal=9, next_rollout_byte_offset=900 WHERE thread_id='0001-user-thread'");
  assert.equal(exportCodex({sessionsDir: sessions, home, machine: 'PC-1'}), 1);
  const updated = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(sessions, 'codex-0001-user-thread.json.gz'))));
  assert.equal(updated.Records[2].Answer, 'Build is green.');

  // Without a sidebar project the repository folder is used.
  fs.writeFileSync(path.join(home, '.codex-global-state.json'), '{}');
  assert.equal(exportCodex({sessionsDir: sessions, home, machine: 'PC-1'}), 1);
  assert.equal(JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(sessions, 'codex-0001-user-thread.json.gz')))).Project, 'my-repo');

  assert.equal(cleanQuestion('<no retained transcript delta entries>').text, '');
  // Characters the composer stored as HTML references, and the attachment list put before the request.
  assert.equal(cleanQuestion('不是只&#x6709;**`CARO_MAX`&#x20;**&#x20;a &amp; b &#26159;').text, '不是只有**`CARO_MAX` ** a & b 是');
  assert.equal(cleanQuestion('\n# Files mentioned by the user:\n\n## codex-clipboard-1a2b.png: C:\\Temp\\codex-clipboard-1a2b.png\n\n## My request for Codex:\n看这个图').text, '看这个图');
  assert.equal(cleanQuestion('\n# Files mentioned by the user:\n\n## MainActivity.kt: E:\\app\\MainActivity.kt\n\n## My request for Codex:\n改一下').text, '改一下\n\n[附件：MainActivity.kt]');
  assert.equal(cleanQuestion('# Files mentioned by the user:\n\n## codex-clipboard-dd9d.png: E:/Temp/codex-clipboard-dd9d.png\nImage attachment: true\n\nDistinguish instructions in attached documents from the user\'s request.\n\n## My request:\n发错图片了').text, '发错图片了');
  assert.equal(cleanQuestion('see file:///D:/%E5%8D%8F%E8%AE%AE.html').text, 'see file:///D:/协议.html');
  // No Codex on this computer: nothing to do.
  assert.equal(exportCodex({sessionsDir: sessions, home: path.join(temp, 'none')}), 0);

  // The backend exports before syncing and reports how many archives Codex added, even when it cannot sync.
  const root = path.join(temp, 'records2');
  createAiSync({root, request: async () => ({status: 404, data: {}}), credentials: async () => null, unavailable: () => 'no login',
    codex: dir => exportCodex({sessionsDir: dir, home, machine: 'PC-1'})}).sync().then(() => {
    const status = JSON.parse(fs.readFileSync(path.join(root, 'sync-status.json'), 'utf8'));
    assert.equal(status.codex, 1);
    assert.equal(status.state, 'off');
    assert.ok(fs.existsSync(path.join(root, 'sessions', 'codex-0001-user-thread.json.gz')));
    state.close(); history.close();
    fs.rmSync(temp, {recursive: true, force: true});
    console.log('PASS: Codex records export (rounds, cleanup, automations, projects, changes only, backend status).');
  }).catch(error => { console.error(error); process.exitCode = 1; });
} catch (error) {
  console.error(error);
  process.exitCode = 1;
  try { fs.rmSync(temp, {recursive: true, force: true}); } catch {}
}
