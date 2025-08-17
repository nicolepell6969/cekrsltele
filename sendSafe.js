module.exports = function applySendSafe(bot){
  if (!bot || typeof bot.sendMessage !== 'function') return;
  const orig = {
    sendMessage: bot.sendMessage.bind(bot),
    sendPhoto: bot.sendPhoto ? bot.sendPhoto.bind(bot) : null,
    sendDocument: bot.sendDocument ? bot.sendDocument.bind(bot) : null
  };
  const SAFE_BODY = 3900;
  const CAPTION_LIMIT = 1024;

  function splitSmart(text, max=SAFE_BODY){
    const t = String(text ?? '');
    if (t.length <= max) return [t];
    const out=[]; let rest=t;
    const cut=(s,limit)=>{
      if (s.length<=limit) return [s,''];
      const seg=s.slice(0,limit);
      const a=seg.lastIndexOf('\n\n'); if(a>0) return [seg.slice(0,a), s.slice(a)];
      const b=seg.lastIndexOf('\n');  if(b>0) return [seg.slice(0,b), s.slice(b)];
      const c=seg.lastIndexOf(' ');   if(c>0) return [seg.slice(0,c), s.slice(c)];
      return [seg, s.slice(seg.length)];
    };
    while(rest.length){ const [h,t2]=cut(rest,max); if(h) out.push(h); rest=t2; }
    return out;
  }

  bot.sendLong = async (chatId, text, extra={}) => {
    const parts = splitSmart(text, SAFE_BODY); let last;
    for (const p of parts){
      const ex={...extra}; if (ex.parse_mode) delete ex.parse_mode;
      last = await orig.sendMessage(chatId, p, ex);
    }
    return last;
  };

  bot.sendMessage = async (chatId, text, extra={}) => {
    const s = String(text ?? '');
    if (s.length <= SAFE_BODY) {
      const ex={...extra}; if (s.length>SAFE_BODY-50 && ex.parse_mode) delete ex.parse_mode;
      return orig.sendMessage(chatId, s, ex);
    }
    return bot.sendLong(chatId, s, extra);
  };

  if (orig.sendPhoto){
    bot.sendPhoto = async (chatId, photo, extra={}) => {
      const ex={...(extra||{})}; const cap = ex.caption?String(ex.caption):'';
      if (cap.length > CAPTION_LIMIT){
        delete ex.caption; if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendPhoto(chatId, photo, ex);
        await bot.sendLong(chatId, cap, {});
        return res;
      } else {
        if (cap.length>CAPTION_LIMIT-20 && ex.parse_mode) delete ex.parse_mode;
        return orig.sendPhoto(chatId, photo, ex);
      }
    };
  }

  if (orig.sendDocument){
    bot.sendDocument = async (chatId, doc, extra={}) => {
      const ex={...(extra||{})}; const cap = ex.caption?String(ex.caption):'';
      if (cap.length > CAPTION_LIMIT){
        delete ex.caption; if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendDocument(chatId, doc, ex);
        await bot.sendLong(chatId, cap, {});
        return res;
      } else {
        if (cap.length>CAPTION_LIMIT-20 && ex.parse_mode) delete ex.parse_mode;
        return orig.sendDocument(chatId, doc, ex);
      }
    };
  }
};
