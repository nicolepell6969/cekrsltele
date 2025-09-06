# 🚀 cekrsltele — Telegram Bot Monitoring Metro‑E

<p align="center">
  <a href="https://github.com/nicolepell6969/cekrsltele/blob/main/LICENSE"><img src="https://img.shields.io/github/license/nicolepell6969/cekrsltele" /></a>
  <img src="https://img.shields.io/badge/Node.js-18+-green" />
  <img src="https://img.shields.io/badge/Telegram-Bot-blue" />
</p>

> Bot Telegram untuk membantu tim NOC melakukan pengecekan **RX/Power Level** antar NE dari chat.  
> Mendukung cek 1 NE (semua port) dan cek 2 sisi (A ↔ B) dengan pencarian nama NE yang fleksibel.

---

## ✨ Fitur
- Cek **RX Level** & **Port Status** via scraping (Puppeteer).
- Pencarian lawan link dari kolom **Description** (smart match).
- Auto-normalisasi alias NE (mis. `EN1/OPT`, `H910D/910D`, `CITY-SITE`).
- Mode **1 NE** (ambil semua entry) & **2 NE** (A ↔ B).
- Riwayat pengecekan & tombol **Cek ulang**.
- Siap dijalankan sebagai **systemd service**.

---

## 📦 Instalasi

### 1. Clone repo
```bash
git clone https://github.com/nicolepell6969/cekrsltele
cd cekrsltele
```

### 2. Install dependencies
```bash
npm install
```

### 3. Setup environment
Buat file `.env` dari `.env.example`:
```env
TELEGRAM_BOT_TOKEN=isi_token_bot
HEADLESS=true
PAGE_TIMEOUT_MS=60000
RX_HIGHER_IS_BETTER=true
```

### 4. Jalankan bot
```bash
node bot.js
```

Atau dengan **systemd service** (production).

---

## 💡 Penggunaan

**Cek dua NE:**
```
/cek NE-A NE-B
```

**Cek satu NE:**
```
/cek NE-A
```

**Lihat riwayat:**
```
/history
```

Bot juga bisa parsing teks bebas → otomatis memberi saran `/cek`.

---

## 📂 Struktur Project
```
├── bot.js                # Entry bot Telegram
├── checkMetroStatus.js   # Scraping RX/Port + matching lawan
├── textToCommand.js      # Ekstrak NE dari teks bebas
├── package.json
├── .env.example
├── .gitignore
└── Dockerfile
```

---

## 🛠️ Teknologi
- [Node.js](https://nodejs.org)
- [Puppeteer](https://pptr.dev/) untuk scraping
- [node-telegram-bot-api](https://github.com/yagop/node-telegram-bot-api)

---

## 📜 Lisensi
MIT License © 2025 — [nicolepell6969](https://github.com/nicolepell6969)
