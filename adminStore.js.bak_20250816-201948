// adminStore.js - simple persistent admin manager
const fs = require('fs');
const path = require('path');

const FILE = path.join(__dirname, 'admins.json');

function _readRaw() {
  try {
    if (!fs.existsSync(FILE)) return { admins: [] };
    const raw = fs.readFileSync(FILE, 'utf8');
    const obj = JSON.parse(raw || '{"admins":[]}');
    if (!Array.isArray(obj.admins)) obj.admins = [];
    return obj;
  } catch (e) {
    return { admins: [] };
  }
}
function _writeRaw(obj) {
  try { fs.writeFileSync(FILE, JSON.stringify(obj, null, 2)); } catch (e) {}
}

function seedFromEnv() {
  const fromEnv = String(process.env.ADMIN_IDS || '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean)
    .map(x => String(Number(x)).trim())
    .filter(Boolean);
  if (!fromEnv.length) return;
  const obj = _readRaw();
  const set = new Set(obj.admins.map(String));
  for (const id of fromEnv) set.add(id);
  obj.admins = Array.from(set);
  _writeRaw(obj);
}

function listAdmins() {
  const obj = _readRaw();
  return obj.admins.map(String);
}
function isAdmin(id) {
  const sid = String(id);
  return listAdmins().includes(sid);
}
function addAdmin(id) {
  const sid = String(Number(id));
  if (!sid || sid === 'NaN') throw new Error('ID tidak valid');
  const obj = _readRaw();
  const set = new Set(obj.admins.map(String));
  set.add(sid);
  obj.admins = Array.from(set);
  _writeRaw(obj);
  return obj.admins;
}
function removeAdmin(id) {
  const sid = String(Number(id));
  const obj = _readRaw();
  obj.admins = obj.admins.map(String).filter(x => x !== sid);
  _writeRaw(obj);
  return obj.admins;
}

module.exports = {
  seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin
};
