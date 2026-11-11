// Turns off the browser's own password saving and form autofill in the dedicated T Notes profile.
// Usage: node browser-prefs.cjs <profile directory>
// Run it only while no browser is using the profile: a running browser rewrites this file when it exits.
const fs = require('node:fs');
const path = require('node:path');

const profile = process.argv[2];
if (!profile || !path.isAbsolute(profile)) process.exit(2);
const file = path.join(profile, 'Default', 'Preferences');
// The master password and the accounts stored in records must never reach the browser's password manager.
const wanted = {
  'credentials_enable_service': false,
  'credentials_enable_autosignin': false,
  'profile.password_manager_enabled': false,
  'autofill.profile_enabled': false,
  'autofill.credit_card_enabled': false
};

let prefs = {};
if (fs.existsSync(file)) {
  // An unreadable file is left alone; the browser repairs or replaces it itself.
  try { prefs = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { process.exit(3); }
}
if (prefs === null || typeof prefs !== 'object' || Array.isArray(prefs)) process.exit(3);

let changed = false;
for (const [key, value] of Object.entries(wanted)) {
  const parts = key.split('.');
  let node = prefs;
  for (const part of parts.slice(0, -1)) {
    if (node[part] === null || typeof node[part] !== 'object' || Array.isArray(node[part])) node[part] = {};
    node = node[part];
  }
  const last = parts[parts.length - 1];
  if (node[last] !== value) { node[last] = value; changed = true; }
}
if (changed) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file + '.tnotes-tmp', JSON.stringify(prefs));
  fs.renameSync(file + '.tnotes-tmp', file);
}
