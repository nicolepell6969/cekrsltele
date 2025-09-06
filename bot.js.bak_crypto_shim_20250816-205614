require("crypto");
require('dotenv').config({ path: __dirname + '/.env' });

const fs = require('fs');
const TelegramBot = require('node-telegram-bot-api');

// optional modules
let checkMetroStatus=null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan. /cek akan gagal.'); }

// === admin store ===
let adminStore=null;
try { adminStore = require('./adminStore'); adminStore.seedFromEnv?.(); }
catch {
  // fallback admin store sederhana (in-memory + admins.json)
  const path = require('path'); const FILE = path.join(__dirname,'admins.json');
  function _read(){ try{ if(!fs.existsSync(FILE)) return {admins:[]}; return JSON.parse(fs.readFileSync(FILE,'utf8')||'{"admins":[]}'); }catch{return{admins:[]}} }
  function _write(o){ try{ fs.writeFileSync(FILE, JSON.stringify(o,null,2)); }catch{} }
  function seedFromEnv(){
    const ids = String(process.env.ADMIN_IDS||'').split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean);
    if (!ids.length) return; const o=_read(); const set=new Set((o.admins||[]).map(String)); ids.forEach(i=>set.add(i)); o.admins=Array.from(set); _write(o);
  }
  function listAdmins(){ return (_read().admins||[]).map(String); }
  function isAdmin(id){ return listAdmins().includes(String(id)); }
  function addAdmin(id){ const sid=String(Number(id)); if(!sid||sid==='NaN') throw new Error('ID tidak valid'); const o=_read(); const set=new Set((o.admins||[]).map(String)); set.add(sid); o.admins=Array.from(set); _write(o); return o.admins; }
  function removeAdmin(id){ const sid=String(Number(id)); const o=_read(); o.admins=(o.admins||[]).map(String).filter(x=>x!==sid); _write(o); return o.admins; }
  adminStore = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
  adminStore.seedFromEnv();
}

// === Telegram init ===
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

// === WhatsApp (opsional) ===
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient=null, makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try { ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys')); } catch {}
async function waStart(notifyChatId){
  if (waClient || !makeWASocket) return;
  const { state, saveCreds } = await useMultiFileAuthState(__dirname + '/wa_auth');
  let version=[2,3000,0]; try{ ({version} = await fetchLatestBaileysVersion()); }catch{}
  const sock = makeWASocket({ version, auth: state, printQRInTerminal:false, syncFullHistory:false, browser:['cekrsltele','Chrome','1.0'] });
  waClient=sock;
  sock.ev.on('creds.update', saveCreds);
  sock.ev.on('connection.update',(u)=>{
    const { connection, lastDisconnect, qr } = u;
    if (qr && notifyChatId){
      // kirim QR ascii via Telegram
      try {
        const qrt = require('qrcode-terminal');
        let ascii=''; qrt.generate(qr,{small:true}, c=>ascii=c);
        bot.sendMessage(notifyChatId, 'QR WhatsApp (scan di aplikasi WhatsApp):\n\n'+ascii);
      } catch(e){ bot.sendMessage(notifyChatId, 'QR tersedia namun gagal dirender: '+e.message); }
    }
    if (connection==='open' && notifyChatId) bot.sendMessage(notifyChatId,'WhatsApp tersambung.');
    if (connection==='close' && notifyChatId){
      const reason=(lastDisconnect && lastDisconnect.error && lastDisconnect.error?.message)||'unknown';
      bot.sendMessage(notifyChatId,'WhatsApp terputus: '+reason);
      waClient=null;
      if (WA_ENABLED) setTimeout(()=>waStart(notifyChatId),5000);
    }
  });
}
async function waStop(){ try{ if(waClient?.ws) waClient.ws.close(); }catch{} try{ await waClient?.end?.(); }catch{} waClient=null; }
function waStatusText(){ return 'WA_ENABLED='+WA_ENABLED+' | status='+(waClient?'CONNECTED':'OFFLINE'); }

// === History sederhana ===
const historyFilePath='./history.json';
let history=[]; try{ if(fs.existsSync(historyFilePath)){ const raw=fs.readFileSync(historyFilePath,'utf8'); if(raw) history=JSON.parse(raw);} }catch{ history=[]; }
function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); }catch{} }
function isDuplicate(ne1,ne2){ return history.some(h => (h.ne1===ne1&&h.ne2===ne2)||(h.ne1===ne2&&h.ne2===ne1)); }
function addHistory(ne1, ne2, result, name, startTime, endTime){
  if (ne2 && isDuplicate(ne1,ne2)) return;
  const timestamp=new Date(startTime).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'});
  const shortNe1=(String(ne1).split('-')[1]||ne1).slice(0,4);
  const shortNe2=ne2?(String(ne2).split('-')[1]||ne2).slice(0,4):'';
  const duration=(endTime-startTime)/1000;
  history.push({name,ne1,ne2:ne2||'',shortNe1,shortNe2,result,timestamp,duration});
  saveHistory();
}

// === utils ===
function runWithTimeout(promise, ms, tag='op'){
  return Promise.race([ promise, new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout '+ms+'ms @'+tag)), ms)) ]);
}
function requireAdmin(msg, fn){
  const id = (msg.from && msg.from.id) || msg.chat?.id;
  if (!adminStore.isAdmin(id)) return bot.sendMessage(msg.chat.id,'Perintah ini khusus admin.');
  return fn();
}

// === Message handler ===
bot.on('message', async (msg)=>{
  const chatId=msg.chat.id;
  const text=String(msg.text||'').trim();
  const low=text.toLowerCase();

  const PUBLIC_CMDS = new Set(['/cek','/history','/help','/start']);
  const ADMIN_CMDS  = new Set(['/admins','/add_admin','/remove_admin','/wa_status','/wa_enable','/wa_disable','/wa_pair']);

  const isCommand = text.startsWith('/');
  const cmdOnly   = isCommand ? text.split(/\s+/,1)[0].toLowerCase() : '';

  // Warning hanya untuk command tidak dikenal (bukan text biasa)
  if (isCommand && !PUBLIC_CMDS.has(cmdOnly) && !ADMIN_CMDS.has(cmdOnly)) {
    return bot.sendMessage(chatId, "Perintah tidak dikenali.\nKetik /help untuk daftar perintah.");
  }

  // /help
  if (low==='/help' || low==='/start'){
    const help=[
      'Daftar Perintah:',
      '/cek NE_A NE_B   → cek dua sisi',
      '/cek NE_A        → cek satu NE (RX & Port)',
      '/history         → riwayat pengecekan',
      '',
      'Admin:',
      '/admins, /add_admin <id>, /remove_admin <id>',
      '/wa_status, /wa_enable, /wa_disable, /wa_pair'
    ].join('\n');
    return bot.sendMessage(chatId, help);
  }

  // Admin
  if (low==='/admins'){
    return requireAdmin(msg, ()=> bot.sendMessage(chatId, 'Admin:\n'+(adminStore.listAdmins().map(a=>'- '+a).join('\n')||'(kosong)')));
  }
  if (low.startsWith('/add_admin')){
    return requireAdmin(msg, ()=>{
      const id=text.split(/\s+/,2)[1];
      if(!id) return bot.sendMessage(chatId,'Format: /add_admin <telegram_id>');
      try { adminStore.addAdmin(id); bot.sendMessage(chatId,'Admin '+id+' ditambahkan.'); }
      catch(e){ bot.sendMessage(chatId,'Gagal: '+e.message); }
    });
  }
  if (low.startsWith('/remove_admin')){
    return requireAdmin(msg, ()=>{
      const id=text.split(/\s+/,2)[1];
      if(!id) return bot.sendMessage(chatId,'Format: /remove_admin <telegram_id>');
      adminStore.removeAdmin(id); bot.sendMessage(chatId,'Admin '+id+' dihapus.');
    });
  }
  if (low==='/wa_status'){ return requireAdmin(msg, ()=> bot.sendMessage(chatId, waStatusText())); }
  if (low==='/wa_enable'){ return requireAdmin(msg, async()=>{ WA_ENABLED=true; bot.sendMessage(chatId,'WA enabled. Menghubungkan...'); await waStart(chatId); }); }
  if (low==='/wa_disable'){ return requireAdmin(msg, async()=>{ WA_ENABLED=false; await waStop(); bot.sendMessage(chatId,'WA disabled.'); }); }
  if (low==='/wa_pair'){ return requireAdmin(msg, async()=>{ if(!WA_ENABLED) bot.sendMessage(chatId,'WA_ENABLED masih false. /wa_enable dulu.'); await waStart(chatId); }); }

  // /history
  if (low==='/history'){
    if (!history.length) return bot.sendMessage(chatId,'Belum ada riwayat.');
    const buttons = history.map((h,i)=>[
      {text:`Ulangi ${h.shortNe1}${h.shortNe2?` ↔ ${h.shortNe2}`:''}`, callback_data:`retry_${i}`},
      {text:`Hapus ${h.shortNe1}${h.shortNe2?` ↔ ${h.shortNe2}`:''}`,  callback_data:`delete_${i}`}
    ]);
    return bot.sendMessage(chatId,'Klik untuk cek ulang / hapus:', { reply_markup:{ inline_keyboard: buttons }});
  }

  // ===== /cek (robust 1 NE & 2 NE) =====
  if (/^\/cek(\s+|$)/.test(low)) {
    if (!checkMetroStatus) return bot.sendMessage(chatId,'checkMetroStatus.js tidak tersedia di server.');

    // Buang '/cek' lalu split argumen longgar (multispasi/newline)
    const tail = text.replace(/^\/cek/, '');
    const parts = tail.split(/\s+/).map(x=>x.trim()).filter(Boolean);

    // 1 NE
    if (parts.length===1){
      const ne = parts[0];
      await bot.sendMessage(chatId,'Cek satu NE: '+ne+' ...');
      try{
        const start=Date.now();
        const result = await runWithTimeout(
          checkMetroStatus.checkSingleNE(ne),
          Number(process.env.PAGE_TIMEOUT_MS||90000),
          'cek-1NE'
        );
        const end=Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${result||'(tidak ada data diterima)'}`);
      } catch(e){
        return bot.sendMessage(chatId, 'Gagal cek 1 NE: '+(e?.message||String(e)));
      }
    }

    // 2 NE
    if (parts.length>=2){
      const ne1=parts[0], ne2=parts[1];
      await bot.sendMessage(chatId,'ONCEK, DITUNGGU');
      try{
        const start=Date.now();
        const r1 = await runWithTimeout(checkMetroStatus(ne1,ne2,{mode:'normal'}), Number(process.env.PAGE_TIMEOUT_MS||90000), 'cek-A');
        const r2 = await runWithTimeout(checkMetroStatus(ne2,ne1,{mode:'normal'}), Number(process.env.PAGE_TIMEOUT_MS||90000), 'cek-B');
        const end=Date.now();
        const combined = `${r1}\n────────────\n${r2}`;
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${combined}`, {
          reply_markup:{ inline_keyboard: [[{ text:'Cek ulang', callback_data:`retry_last_${history.length-1}` }]] }
        });
      } catch(e){
        return bot.sendMessage(chatId,'Gagal cek 2 sisi: '+(e?.message||String(e)));
      }
    }

    return bot.sendMessage(chatId,'Format: /cek <NE1> [NE2]');
  }

  // Teks bebas: biarkan diam (tidak memunculkan warning)
});

// === callback buttons ===
bot.on('callback_query', async (q)=>{
  const { data, message } = q; const chatId=message.chat.id;
  try{
    await bot.answerCallbackQuery(q.id);

    if (data.startsWith('runcek_')){
      const [, ne1, ne2] = data.split('_');
      await bot.sendMessage(chatId, 'Checking: '+ne1+' ↔ '+ne2+' ...');
      const r1 = await checkMetroStatus(ne1,ne2,{mode:'normal'});
      const r2 = await checkMetroStatus(ne2,ne1,{mode:'normal'});
      const end = Date.now();
      return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${r1}\n────────────\n${r2}`, {
        reply_markup:{ inline_keyboard: [[{ text:'Cek ulang', callback_data:`runcek_${ne1}_${ne2}` }]] }
      });
    }

    if (data.startsWith('runcek1_')){
      const ne = data.substring('runcek1_'.length);
      await bot.sendMessage(chatId, 'Checking: '+ne+' ...');
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${result}`, {
        reply_markup:{ inline_keyboard: [[{ text:'Cek ulang', callback_data:`runcek1_${ne}` }]] }
      });
    }

    if (data.startsWith('retry_')){
      let index=null;
      if (data.startsWith('retry_last_')) index=parseInt(data.split('_').pop(),10);
      else index=parseInt(data.split('_')[1],10);
      const entry=history[index];
      if (!entry) return;
      if (!entry.ne2){
        await bot.sendMessage(chatId,'Checking: '+entry.ne1+' ...');
        const result=await checkMetroStatus.checkSingleNE(entry.ne1);
        const end=Date.now();
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${result}`, {
          reply_markup:{ inline_keyboard: [[{ text:'Cek ulang', callback_data:`runcek1_${entry.ne1}` }]] }
        });
      } else {
        await bot.sendMessage(chatId,'Checking: '+entry.ne1+' ↔ '+entry.ne2+' ...');
        const r1=await checkMetroStatus(entry.ne1, entry.ne2, {mode:'normal'});
        const r2=await checkMetroStatus(entry.ne2, entry.ne1, {mode:'normal'});
        const end=Date.now();
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${r1}\n────────────\n${r2}`, {
          reply_markup:{ inline_keyboard: [[{ text:'Cek ulang', callback_data:`runcek_${entry.ne1}_${entry.ne2}` }]] }
        });
      }
    }

    if (data.startsWith('delete_')){
      const index=parseInt(data.split('_')[1],10);
      const entry=history[index];
      if (!entry) return;
      history.splice(index,1); saveHistory();
      return bot.sendMessage(chatId, `Riwayat ${entry.ne1}${entry.ne2?` ↔ ${entry.ne2}`:''} dihapus.`);
    }
  } catch(e){
    console.error('callback error:', e);
    bot.answerCallbackQuery(q.id,{ text:'Terjadi kesalahan. Coba lagi.', show_alert:true }).catch(()=>{});
  }
});

// Graceful shutdown
function quit(){ try{bot.stopPolling();}catch{} setTimeout(()=>process.exit(0),500); }
process.on('SIGTERM', quit);
process.on('SIGINT', quit);

// Autostart WA jika WA_ENABLED=true
if (WA_ENABLED) { waStart(null).catch(()=>{}); }

// ===== DEBUG: kirim error ke admin via Telegram =====
function _getAdminIds(){
  try {
    const list = (adminStore && typeof adminStore.listAdmins==='function')
      ? adminStore.listAdmins()
      : [];
    return (list||[]).map(x=>String(x)).filter(Boolean);
  } catch { return []; }
}
function notifyAdmins(text){
  try {
    const ids = _getAdminIds();
    if (!ids.length) return;
    const msg = `⚠️ [DEBUG ERROR]\n${text}`;
    for (const id of ids) { bot.sendMessage(id, msg).catch(()=>{}); }
  } catch {}
}

// polling error → kirim ke admin juga
try {
  bot.on('polling_error', (err)=>{
    const body = (err && err.response && err.response.body) ? err.response.body : (err && err.message ? err.message : String(err));
    notifyAdmins(`[polling_error] ${body}`);
  });
} catch {}

// global handlers
process.on('uncaughtException', (err)=>{
  const msg = (err && err.stack) ? err.stack : String(err);
  try { console.error('uncaughtException', err); } catch {}
  notifyAdmins(`Uncaught Exception:\n${msg}`);
});
process.on('unhandledRejection', (reason, p)=>{
  const msg = (reason && reason.stack) ? reason.stack : String(reason);
  try { console.error('unhandledRejection', reason); } catch {}
  notifyAdmins(`Unhandled Rejection:\n${msg}`);
});

// util opsional untuk kirim debug manual dari tempat lain:
// bot.sendAdminDebug?.('teks debug');
// atau panggil notifyAdmins('pesan');
bot.sendAdminDebug = (text)=> { try { notifyAdmins(text); } catch {} };
