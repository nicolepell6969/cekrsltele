// === CRYPTO SHIM (untuk Baileys) ===
(() => {
  try {
    const nodeCrypto = require('node:crypto');
    if (!globalThis.crypto) globalThis.crypto = nodeCrypto.webcrypto || nodeCrypto;
  } catch {
    try {
      const c = require('crypto');
      if (!globalThis.crypto) globalThis.crypto = c;
    } catch {}
  }
})();
require('dotenv').config({ path: __dirname + '/.env' });

const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');
const TelegramBot = require('node-telegram-bot-api');
const QR = require('qrcode');

// ====== Optional modules ======
let checkMetroStatus = null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan'); }

let { buildCekCommandFromText } = (() => {
  try { return require('./textToCommand'); }
  catch { return { buildCekCommandFromText: (t)=>({cmd:null,list:[],note:'modul textToCommand.js tidak ada'}) }; }
})();

// === Admin store (persisten, punya fallback) ===
let adminStore = null;
try { adminStore = require('./adminStore'); adminStore.seedFromEnv?.(); }
catch {
  const FILE = path.join(__dirname,'admins.json');
  function _read(){ try{ if(!fs.existsSync(FILE)) return {admins:[]}; return JSON.parse(fs.readFileSync(FILE,'utf8')||'{"admins":[]}'); }catch{return{admins:[]}} }
  function _write(o){ try{ fs.writeFileSync(FILE, JSON.stringify(o,null,2)); }catch{} }
  function seedFromEnv(){ const ids=String(process.env.ADMIN_IDS||'').split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean); if(!ids.length) return; const o=_read(); const set=new Set((o.admins||[]).map(String)); ids.forEach(i=>set.add(i)); o.admins=[...set]; _write(o); }
  function listAdmins(){ return (_read().admins||[]).map(String); }
  function isAdmin(id){ return listAdmins().includes(String(id)); }
  function addAdmin(id){ const sid=String(Number(id)); if(!sid||sid==='NaN') throw new Error('ID tidak valid'); const o=_read(); const set=new Set((o.admins||[]).map(String)); set.add(sid); o.admins=[...set]; _write(o); return o.admins; }
  function removeAdmin(id){ const sid=String(Number(id)); const o=_read(); o.admins=(o.admins||[]).map(String).filter(x=>x!==sid); _write(o); return o.admins; }
  adminStore = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
  adminStore.seedFromEnv();
}
function isAdminUser(userId){
  try { return adminStore?.isAdmin?.(String(userId)) || false; } catch { return false; }
}

// === Telegram init ===
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });

// ====== Safe long sender (apply sendSafe jika ada) ======
const applySendSafe = (() => { try { return require('./sendSafe'); } catch { return null; }})();
try{ if (applySendSafe) applySendSafe(bot); }catch(e){ console.error('WARN sendSafe:', e?.message||e); }

// ====== Helper: kirim panjang aman (fallback) ======
async function sendLong(chatId, text, extra = {}) {
  const MAX = 3900; // buffer <4096
  const t = String(text ?? '');
  if (t.length <= MAX) return bot.sendMessage(chatId, t, extra);
  const lines = t.split('\n');
  let buf = '';
  let last;
  for (const line of lines) {
    const would = buf ? (buf + '\n' + line) : line;
    if (would.length > MAX) {
      last = await bot.sendMessage(chatId, buf, extra);
      buf = line;
    } else {
      buf = would;
    }
  }
  if (buf) last = await bot.sendMessage(chatId, buf, extra);
  return last;
}

// ====== Edit helpers: hindari 400 "message is not modified" ======
const _msgCache = new Map(); // key: chatId:messageId -> {text, markupJSON}

function cacheKey(chatId, messageId){ return `${chatId}:${messageId}`; }
function sameMarkup(a,b){ return JSON.stringify(a||{}) === JSON.stringify(b||{}); }

async function safeEditText(chatId, messageId, newText, opts = {}){
  const key = cacheKey(chatId, messageId);
  const prev = _msgCache.get(key) || {};
  const nextMarkup = opts.reply_markup || prev.markup || undefined;
  const sameText = String(prev.text||'') === String(newText||'');
  const sameMk = sameMarkup(prev.markup, nextMarkup);
  if (sameText && sameMk) return null; // nothing to do
  try{
    const res = await bot.editMessageText(newText, { chat_id: chatId, message_id: messageId, ...opts });
    _msgCache.set(key, { text: newText, markup: nextMarkup });
    return res;
  } catch(e){
    // kalau error text sama, coba hanya ganti markup
    if (/message is not modified/i.test(String(e?.message||''))) return null;
    throw e;
  }
}
async function safeEditMarkup(chatId, messageId, markup){
  const key = cacheKey(chatId, messageId);
  const prev = _msgCache.get(key) || {};
  if (sameMarkup(prev.markup, markup)) return null;
  try{
    const res = await bot.editMessageReplyMarkup(markup || {}, { chat_id: chatId, message_id: messageId });
    _msgCache.set(key, { text: prev.text, markup });
    return res;
  }catch(e){
    if (/message is not modified/i.test(String(e?.message||''))) return null;
    throw e;
  }
}

// ====== History (in-memory + file) ======
const HIST_FILE = path.join(__dirname, 'history.json');
let history = [];
function loadHistory(){
  try { history = JSON.parse(fs.readFileSync(HIST_FILE,'utf8')); if(!Array.isArray(history)) history=[]; }
  catch { history = []; }
}
function saveHistory(){
  try { fs.writeFileSync(HIST_FILE, JSON.stringify(history,null,2)); } catch {}
}
function addHistory(ne1, ne2, text, label, start, end){
  history.push({ ts: Date.now(), ne1, ne2: ne2||null, text, label, start, end });
  if (history.length > 100) history.shift();
  saveHistory();
}
function createHistoryButtons(){
  const rows = [];
  for (let i = history.length - 1; i >= 0; i--){
    const e = history[i];
    const label = e.ne2 ? `${e.ne1} ↔ ${e.ne2}` : e.ne1;
    rows.push([
      { text: `▶️ ${label}`, callback_data: e.ne2 ? `runcek_${e.ne1}_${e.ne2}` : `runcek1_${e.ne1}` },
      { text: '🗑️ Hapus', callback_data: `delete_${i}` }
    ]);
  }
  return rows.length ? rows : [[{ text: 'Kosong', callback_data: 'noop' }]];
}

// ====== Misc helpers ======
async function runWithTimeout(promise, ms){
  return await Promise.race([
    promise,
    new Promise((_,rej)=> setTimeout(()=> rej(new Error('Timeout')), ms))
  ]);
}
function fmtChecked(now){
  return `🕛Checked Time: ${new Date(now).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}`;
}

// ====== Git helpers (status/diff/push + auto-notify) ======
const REPO_DIR = __dirname;
let AUTOPUSH_ENABLED = true;
const AUTOPUSH_INTERVAL_MS = 2 * 60 * 1000;
let lastNotifiedHash = '';

function runCmd(cmd){
  return new Promise((resolve) => {
    exec(cmd, { cwd: REPO_DIR, maxBuffer: 10 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ ok: !err, code: err ? err.code : 0, stdout: stdout?.toString() || '', stderr: stderr?.toString() || '', error: err });
    });
  });
}
async function gitEnsureIgnoreEnv(){
  const gi = path.join(REPO_DIR, '.gitignore');
  try{
    const cur = fs.existsSync(gi) ? fs.readFileSync(gi,'utf8') : '';
    if (!cur.split('\n').some(l => l.trim() === '.env')) {
      fs.writeFileSync(gi, (cur ? cur.trim()+'\n' : '') + '.env\n');
      await runCmd('git add .gitignore');
      await runCmd(`git commit -m "chore: ensure .env ignored" || true`);
    }
  }catch{}
}
async function gitStatusPorcelain(){ const r = await runCmd('git status --porcelain'); return r.ok ? r.stdout.trim() : ''; }
async function gitBranch(){ const r = await runCmd('git rev-parse --abbrev-ref HEAD'); return r.ok ? r.stdout.trim() : 'main'; }
async function gitDiffStat(){ const r = await runCmd('git diff --stat'); return r.ok ? (r.stdout.trim() || '(tidak ada diff)') : r.stderr || '(gagal ambil diff)'; }
async function gitShortLog(){
  const st = await gitStatusPorcelain();
  if (!st) return 'Tidak ada perubahan lokal.';
  return 'Perubahan lokal:\n' + st.split('\n').map(l=>'• '+l.trim()).join('\n');
}
async function gitPushAutoCommit(customMsg){
  await gitEnsureIgnoreEnv();
  const branch = await gitBranch();
  await runCmd('git add .');
  const msg = customMsg || `Auto update: ${new Date().toISOString()}`;
  await runCmd(`git commit -m "${msg.replace(/"/g,'\\"')}" || true`);
  const push = await runCmd(`git push origin ${branch}`);
  return push;
}
async function computeWorkTreeHash(){
  const st = await gitStatusPorcelain();
  if (!st) return '';
  const diff = await runCmd('git diff');
  const payload = st + '\n' + (diff.ok ? diff.stdout : '');
  let h = 0; for (let i=0;i<payload.length;i++){ h=(h*33)^payload.charCodeAt(i); h|=0; }
  return String(h);
}

// ====== WhatsApp (opsional; aman jika modul tidak ada) ======
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient=null, makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try { ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys')); } catch {}

// ====== Bot online ======
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

let lastChatId = null;

// ====== Message handler ======
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  lastChatId = chatId;
  const text = (msg.text || '').trim();
  const low = text.toLowerCase();

  // ===== /help =====
  if (low === '/help') {
    const isAdmin = isAdminUser(msg.from.id);
    const lines = [
      '📋 *Perintah Utama*',
      '/help — daftar perintah',
      '/cek <NE1> [NE2] — cek RX (1 atau 2 sisi, edit 1 pesan)',
      '/history — tombol riwayat',
      '',
      '📲 *WhatsApp*',
      '/wa_status',
      '/wa_enable',
      '/wa_disable',
      '/wa_pair — kirim QR ke sini',
    ];
    if (isAdmin) {
      lines.push(
        '',
        '🛠️ *Admin*',
        '/add_admin <id>',
        '/remove_admin <id>',
        '/admins — list admin',
        '',
        '🐙 *Git*',
        '/git_status — lihat perubahan & tombol push',
        '/git_push [pesan] — push langsung',
        '/git_autopush_on — auto-notify perubahan ON',
        '/git_autopush_off — auto-notify perubahan OFF'
      );
    }
    return bot.sendMessage(chatId, lines.join('\n'), { parse_mode: 'HTML' });
  }

  // ===== /cek =====
  if (low.startsWith('/cek')) {
    const parts = text.split(/\s+/).slice(1).filter(Boolean);
    if (!checkMetroStatus) return bot.sendMessage(chatId, '❌ Modul cek tidak tersedia.');

    // kirim 1 pesan "Checking..." lalu replace
    const checkingText = parts.length >= 2
      ? `🔄 Checking: ${parts[0]} ↔ ${parts[1]}...`
      : (parts.length === 1 ? `🔄 Checking: ${parts[0]}...` : '❌ Format: /cek <NE1> [NE2]');

    const m = await bot.sendMessage(chatId, checkingText, { reply_markup: { inline_keyboard: [] } });
    _msgCache.set(cacheKey(chatId, m.message_id), { text: checkingText, markup: {} });

    if (parts.length === 0) {
      await safeEditText(chatId, m.message_id, '❗ Format: /cek <NE1> [NE2]');
      return;
    }

    // 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        await safeEditText(chatId, m.message_id, `${fmtChecked(end)}\n\n${result}`);
      } catch (e) {
        await safeEditText(chatId, m.message_id, '❌ Gagal cek 1 NE: ' + (e?.message||e));
      }
      return;
    }

    // 2 NE
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      try {
        const start = Date.now();
        // PENTING: panggil SEKALI agar tidak dobel
        const combined = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        await safeEditText(chatId, m.message_id, `${fmtChecked(end)}\n\n${combined}`, {
          reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}_${m.message_id}` }]] }
        });
        await safeEditMarkup(chatId, m.message_id, { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}_${m.message_id}` }]] });
      } catch (e) {
        await safeEditText(chatId, m.message_id, '❌ Gagal cek 2 sisi: ' + (e?.message||e));
      }
      return;
    }
  }

  // ===== /history =====
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    const textHead = '👉 Klik di bawah untuk cek ulang atau hapus riwayat:';
    const sent = await bot.sendMessage(chatId, textHead, {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
    _msgCache.set(cacheKey(chatId, sent.message_id), { text: textHead, markup: { inline_keyboard: createHistoryButtons() } });
    return;
  }

  // ===== Admin commands (singkat) =====
  if (low.startsWith('/add_admin')) {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    const id = text.split(/\s+/)[1];
    if (!id) return bot.sendMessage(chatId, 'Format: /add_admin <id>');
    try { adminStore.addAdmin(id); return bot.sendMessage(chatId, '✅ Admin ditambahkan.'); }
    catch(e){ return bot.sendMessage(chatId, '❌ ' + (e?.message||e)); }
  }
  if (low.startsWith('/remove_admin')) {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    const id = text.split(/\s+/)[1];
    if (!id) return bot.sendMessage(chatId, 'Format: /remove_admin <id>');
    try { adminStore.removeAdmin(id); return bot.sendMessage(chatId, '✅ Admin dihapus.'); }
    catch(e){ return bot.sendMessage(chatId, '❌ ' + (e?.message||e)); }
  }
  if (low === '/admins') {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    const list = adminStore.listAdmins();
    return bot.sendMessage(chatId, list.length ? 'Admin:\n' + list.join('\n') : 'Tidak ada admin.');
  }

  // ===== Git commands =====
  if (low === '/git_status') {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    const branch = await gitBranch();
    const short = await gitShortLog();
    const diff = await gitDiffStat();
    const textOut = [
      `📦 Repo: ${path.basename(__dirname)} (branch: ${branch})`,
      '',
      short,
      '',
      'Ringkasan diff:',
      diff
    ].join('\n');
    const sent = await bot.sendMessage(chatId, textOut, {
      reply_markup: { inline_keyboard: [[
        { text: '⬆️ Push sekarang', callback_data: 'git_push_now' },
        { text: '📄 Lihat diff penuh', callback_data: 'git_show_diff' },
      ],[
        { text: AUTOPUSH_ENABLED ? '⏸️ Auto-notify: ON' : '▶️ Auto-notify: OFF', callback_data: 'git_toggle_autopush' }
      ]] }
    });
    _msgCache.set(cacheKey(chatId, sent.message_id), { text: textOut, markup: { inline_keyboard: [
      [{ text: '⬆️ Push sekarang', callback_data: 'git_push_now' }, { text: '📄 Lihat diff penuh', callback_data: 'git_show_diff' }],
      [{ text: AUTOPUSH_ENABLED ? '⏸️ Auto-notify: ON' : '▶️ Auto-notify: OFF', callback_data: 'git_toggle_autopush' }]
    ] } });
    return;
  }
  if (low.startsWith('/git_push')) {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    const note = text.split(' ').slice(1).join(' ').trim();
    const stat = await gitStatusPorcelain();
    if (!stat) return bot.sendMessage(chatId, '✅ Tidak ada perubahan untuk di-push.');
    const m = await bot.sendMessage(chatId, '🔄 Push in progress...');
    const res = await gitPushAutoCommit(note ? `Manual push: ${note}` : undefined);
    if (!res.ok) return safeEditText(chatId, m.message_id, '❌ Push gagal:\n' + (res.stderr || res.stdout || 'unknown'));
    return safeEditText(chatId, m.message_id, '✅ Push sukses.');
  }
  if (low === '/git_autopush_on') {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    AUTOPUSH_ENABLED = true; return bot.sendMessage(chatId, '✅ Auto-notify perubahan: ON');
  }
  if (low === '/git_autopush_off') {
    if (!isAdminUser(msg.from.id)) return bot.sendMessage(chatId, '❌ Khusus admin.');
    AUTOPUSH_ENABLED = false; return bot.sendMessage(chatId, '✅ Auto-notify perubahan: OFF');
  }

  // ===== Teks bebas -> parsing NE =====
  if (text) {
    const { list } = buildCekCommandFromText(text);
    if (list && list.length === 1) {
      const ne = list[0];
      const msgTxt = `ℹ️ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`;
      const sent = await bot.sendMessage(chatId, msgTxt, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
      _msgCache.set(cacheKey(chatId, sent.message_id), { text: msgTxt, markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] } });
      return;
    }
    if (list && list.length >= 2) {
      const a = list[0], b = list.find(x=>x!==a) || list[1];
      const msgTxt = `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`;
      const sent = await bot.sendMessage(chatId, msgTxt, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
      _msgCache.set(cacheKey(chatId, sent.message_id), { text: msgTxt, markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] } });
      return;
    }
  }
});

// ====== Callback (cek ulang, run now, hapus, git) ======
bot.on('callback_query', async (q)=>{
  const { data, message } = q;
  const chatId = message.chat.id;
  const msgId = message.message_id;

  try {
    await bot.answerCallbackQuery(q.id).catch(()=>{});

    // ---- runcek (dua NE) ----
    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      await safeEditText(chatId, msgId, `🔄 Checking: ${ne1} ↔ ${ne2}...`, { reply_markup: { inline_keyboard: [] } });
      try {
        const start = Date.now();
        const combined = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        await safeEditText(chatId, msgId, `${fmtChecked(end)}\n\n${combined}`, {
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
        });
        await safeEditMarkup(chatId, msgId, { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] });
      } catch(e){
        await safeEditText(chatId, msgId, '❌ Gagal cek 2 sisi: '+(e?.message||e));
      }
      return;
    }

    // ---- runcek1 (satu NE) ----
    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await safeEditText(chatId, msgId, `🔄 Checking: ${ne}...`, { reply_markup: { inline_keyboard: [] } });
      try{
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        await safeEditText(chatId, msgId, `${fmtChecked(end)}\n\n${result}`, {
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
        });
        await safeEditMarkup(chatId, msgId, { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] });
      } catch(e){
        await safeEditText(chatId, msgId, '❌ Gagal cek 1 NE: '+(e?.message||e));
      }
      return;
    }

    // ---- retry_last_i_messageId ----
    if (data.startsWith('retry_last_')) {
      // format terbaru: retry_last_<index>_optionalMessageId
      const arr = data.split('_');
      const index = parseInt(arr[2], 10);
      const e = history[index];
      if (!e) return;
      if (!e.ne2) {
        await safeEditText(chatId, msgId, `🔄 Checking: ${e.ne1}...`, { reply_markup: { inline_keyboard: [] } });
        try{
          const start = Date.now();
          const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
          const end = Date.now();
          addHistory(e.ne1, null, result, e.ne1, start, end);
          await safeEditText(chatId, msgId, `${fmtChecked(end)}\n\n${result}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${e.ne1}` }]] }
          });
          await safeEditMarkup(chatId, msgId, { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${e.ne1}` }]] });
        } catch(err){
          await safeEditText(chatId, msgId, '❌ Gagal cek 1 NE: '+(err?.message||err));
        }
      } else {
        await safeEditText(chatId, msgId, `🔄 Checking: ${e.ne1} ↔ ${e.ne2}...`, { reply_markup: { inline_keyboard: [] } });
        try{
          const start = Date.now();
          const combined = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const end = Date.now();
          addHistory(e.ne1, e.ne2, combined, `${e.ne1} ${e.ne2}`, start, end);
          await safeEditText(chatId, msgId, `${fmtChecked(end)}\n\n${combined}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${e.ne1}_${e.ne2}` }]] }
          });
          await safeEditMarkup(chatId, msgId, { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${e.ne1}_${e.ne2}` }]] });
        } catch(err){
          await safeEditText(chatId, msgId, '❌ Gagal cek 2 sisi: '+(err?.message||err));
        }
      }
      return;
    }

    // ---- delete_i (hapus riwayat & refresh daftar IN PLACE) ----
    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        history.splice(index,1); saveHistory();
        const textHead = history.length ? '👉 Klik di bawah untuk cek ulang atau hapus riwayat:' : '❌ Belum ada riwayat pengecekan.';
        await safeEditText(chatId, msgId, textHead, { reply_markup: { inline_keyboard: createHistoryButtons() } });
        await safeEditMarkup(chatId, msgId, { inline_keyboard: createHistoryButtons() });
      }
      return;
    }

    // ---- Git callbacks ----
    if (data === 'git_push_now') {
      if (!isAdminUser(q.from.id)) return;
      await safeEditMarkup(chatId, msgId, { inline_keyboard: [] });
      const stat = await gitStatusPorcelain();
      if (!stat) {
        await safeEditText(chatId, msgId, '✅ Tidak ada perubahan untuk di-push.');
        return;
      }
      await safeEditText(chatId, msgId, '🔄 Push in progress...');
      const res = await gitPushAutoCommit();
      if (!res.ok) {
        await safeEditText(chatId, msgId, '❌ Push gagal:\n' + (res.stderr || res.stdout || 'unknown'));
      } else {
        await safeEditText(chatId, msgId, '✅ Push sukses.');
      }
      return;
    }

    if (data === 'git_show_diff') {
      if (!isAdminUser(q.from.id)) return;
      const diffFull = await runCmd('git diff');
      const payload = diffFull.ok ? (diffFull.stdout.trim() || '(tidak ada diff)') : (diffFull.stderr || 'gagal ambil diff');
      const MAX = 3900;
      const text = payload.length > MAX ? payload.slice(0, MAX-50) + '\n...\n(terpotong)' : payload;
      await safeEditText(chatId, msgId, '📄 Diff penuh:\n\n' + text, {
        reply_markup: { inline_keyboard: [[{ text: '⬆️ Push sekarang', callback_data: 'git_push_now' }]] }
      });
      await safeEditMarkup(chatId, msgId, { inline_keyboard: [[{ text: '⬆️ Push sekarang', callback_data: 'git_push_now' }]] });
      return;
    }

    if (data === 'git_toggle_autopush') {
      if (!isAdminUser(q.from.id)) return;
      AUTOPUSH_ENABLED = !AUTOPUSH_ENABLED;
      const keyboard = [[
        { text: '⬆️ Push sekarang', callback_data: 'git_push_now' },
        { text: '📄 Lihat diff penuh', callback_data: 'git_show_diff' },
      ],[
        { text: AUTOPUSH_ENABLED ? '⏸️ Auto-notify: ON' : '▶️ Auto-notify: OFF', callback_data: 'git_toggle_autopush' }
      ]];
      await safeEditMarkup(chatId, msgId, { inline_keyboard: keyboard });
      return;
    }

  } catch(err){
    console.error('callback error:', err);
    bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true }).catch(()=>{});
  }
});

// ===== OPTIONAL: kirim error penting ke admin pertama =====
function notifyAdmins(text){
  let target = null;
  try { target = adminStore.listAdmins()?.[0]; } catch {}
  if (target) bot.sendMessage(Number(target), text).catch(()=>{});
}
process.on('unhandledRejection', err=> notifyAdmins('⚠️ unhandledRejection: '+(err?.message||err)));
process.on('uncaughtException', err=> { notifyAdmins('⚠️ uncaughtException: '+(err?.message||err)); setTimeout(()=>process.exit(1), 500); });

// ===== global error handlers =====
process.on('unhandledRejection', async (err) => {
  try { await bot.sendMessage(lastChatId || adminStore.listAdmins()?.[0], '❗ *UnhandledRejection*\n' + (err?.stack || err), { parse_mode:'Markdown' }); } catch {}
});
process.on('uncaughtException', async (err) => {
  try { await bot.sendMessage(lastChatId || adminStore.listAdmins()?.[0], '❗ *UncaughtException*\n' + (err?.stack || err), { parse_mode:'Markdown' }); } catch {}
  setTimeout(() => process.exit(1), 500);
});

// ===== Auto-notify perubahan repo =====
(async function autoNotifyLoop(){
  await gitEnsureIgnoreEnv();
  setInterval(async ()=>{
    if (!AUTOPUSH_ENABLED) return;
    try{
      const st = await gitStatusPorcelain();
      if (!st) { lastNotifiedHash = ''; return; }
      const h = await computeWorkTreeHash();
      if (h && h !== lastNotifiedHash) {
        lastNotifiedHash = h;
        const text = await gitShortLog();
        let target = null;
        try{ target = adminStore.listAdmins?.()[0]; }catch{}
        if (!target) return;
        await bot.sendMessage(Number(target), text, {
          reply_markup: { inline_keyboard: [[
            { text: '⬆️ Push sekarang', callback_data: 'git_push_now' },
            { text: '📄 Lihat diff penuh', callback_data: 'git_show_diff' },
          ]]}
        }).catch(()=>{});
      }
    }catch{}
  }, AUTOPUSH_INTERVAL_MS);
})();
