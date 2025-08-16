const fs = require('fs');
const path = require('path');
const FILE = path.join(__dirname, 'admins.json');

function _read() {
  try {
    if (!fs.existsSync(FILE)) return { admins: [] };
    return JSON.parse(fs.readFileSync(FILE, 'utf8') || '{"admins":[]}');
  } catch {
    return { admins: [] };
  }
}
function _write(obj){ try { fs.writeFileSync(FILE, JSON.stringify(obj, null, 2)); } catch {} }

function seedFromEnv(){
  const seed = String(process.env.ADMIN_IDS || '')
    .split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean);
  if (!seed.length) return;
  const obj=_read(); const set=new Set((obj.admins||[]).map(String));
  for (const id of seed) set.add(id);
  obj.admins = Array.from(set);
  _write(obj);
}
function listAdmins(){ return (_read().admins||[]).map(String); }
function isAdmin(id){ return listAdmins().includes(String(id)); }
function addAdmin(id){
  const sid = String(Number(id)); if (!sid || sid==='NaN') throw new Error('ID tidak valid');
  const obj=_read(); const set=new Set((obj.admins||[]).map(String)); set.add(sid);
  obj.admins = Array.from(set); _write(obj); return obj.admins;
}
function removeAdmin(id){
  const sid=String(Number(id)); const obj=_read();
  obj.admins=(obj.admins||[]).map(String).filter(x=>x!==sid); _write(obj); return obj.admins;
}
module.exports = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
