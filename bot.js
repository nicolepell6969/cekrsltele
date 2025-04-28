const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');  // Mengimpor fungsi dari checkMetroStatus.js

// Ganti dengan token bot Telegram Anda
const token = '7610256789:AAHsiyqSXltoukqqcnJNMxiVOCuDEScdZik';

// Inisialisasi bot Telegram
const bot = new TelegramBot(token, { polling: true });

// Lokasi file log untuk riwayat pengecekan
const historyFilePath = './history.json';

// Membaca riwayat pengecekan dari file saat bot mulai
let history = [];

try {
    if (fs.existsSync(historyFilePath)) {
        const fileData = fs.readFileSync(historyFilePath);
        if (fileData) {
            history = JSON.parse(fileData);
        }
    }
} catch (error) {
    console.error('Gagal membaca atau mengurai file JSON:', error);
    history = [];  // Setel history ke array kosong jika terjadi kesalahan
}

// Fungsi untuk menyimpan riwayat pengecekan ke dalam file log
function saveHistoryToFile() {
    try {
        fs.writeFileSync(historyFilePath, JSON.stringify(history, null, 2));
    } catch (error) {
        console.error('Gagal menyimpan file history.json:', error);
    }
}

// Fungsi untuk membuat riwayat pengecekan
function addHistory(ne1, ne2, result, name, startTime, endTime) {
    const timestamp = new Date(startTime).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });  // Menggunakan timezone Jakarta
    const shortNe1 = ne1.split('-')[1].slice(0, 4);
    const shortNe2 = ne2.split('-')[1].slice(0, 4);
    const duration = (endTime - startTime) / 1000;  // Waktu dalam detik

    history.push({ name, ne1, ne2, shortNe1, shortNe2, result, timestamp, duration });
    // Simpan riwayat ke file log
    saveHistoryToFile();
}

// Fungsi untuk menampilkan riwayat dengan tombol interaktif
function createHistoryButtons() {
    return history.map((entry, index) => {
        return [
            {
                text: `Ulangi ${entry.shortNe1} ↔ ${entry.shortNe2}`,
                callback_data: `retry_${index}`
            },
            {
                text: `Hapus ${entry.shortNe1} ↔ ${entry.shortNe2}`,
                callback_data: `delete_${index}`
            }
        ];
    });
}

// Menangani pesan yang diterima
bot.on('message', async (msg) => {
    const messageText = msg.text.toLowerCase();
    
    // Hanya menangani perintah /cek
    if (messageText.startsWith('/cek ')) {
        const neNames = messageText.split(' ').slice(1).map(name => name.trim());
        
        if (neNames.length !== 2) {
            return bot.sendMessage(msg.chat.id, '❗ Format salah. Harap masukkan dua NE Name. Contoh: /cek SBY-MOOJ-EN1-H910D SBY-PGG-AN1-H8M14');
        }
        
        const [ne1, ne2] = neNames;
        const name = msg.text.split(' ').slice(1).join(' ');  // Mengambil nama pengecekan dari input
        bot.sendMessage(msg.chat.id, `🔄 *ONCEK, DITUNGGU*`);

        // Mencatat waktu mulai pengecekan
        const startTime = new Date().getTime();
        
        // Cek dua arah (ne1 -> ne2 dan ne2 -> ne1)
        const result1 = await checkMetroStatus(ne1, ne2, { mode: 'normal' });
        const result2 = await checkMetroStatus(ne2, ne1, { mode: 'normal' });

        // Mencatat waktu selesai pengecekan
        const endTime = new Date().getTime();

        // Gabungkan hasilnya
        const combinedResult = result1 + '\n────────────\n' + result2;

        // Hitung durasi pengecekan dalam detik
        const duration = (endTime - startTime) / 1000;

        // Simpan riwayat pengecekan dengan durasi waktu
        addHistory(ne1, ne2, combinedResult, name, startTime, endTime);

        // Mengirim hasil dengan format yang diperbarui
        bot.sendMessage(msg.chat.id, `🕛Checked Time: ${new Date(endTime).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combinedResult}`);

        // Menampilkan tombol riwayat pengecekan
    } else if (messageText === '/history') {
        // Menampilkan seluruh riwayat pengecekan dengan tombol interaktif
        if (history.length > 0) {
            let historyText = '📜 Riwayat Pengecekan:\n';
            history.forEach((entry, index) => {
                // Pastikan 'duration' terdefinisi sebelum menggunakan toFixed
                const durationText = entry.duration ? entry.duration.toFixed(2) : 'N/A';
                historyText += `\n${index + 1}. ${entry.name} - ${entry.ne1} ↔ ${entry.ne2} | Waktu: ${entry.timestamp} | Durasi: ${durationText} detik`;
            });

            //bot.sendMessage(msg.chat.id, historyText);

            // Menampilkan tombol riwayat pengecekan
            bot.sendMessage(msg.chat.id, '👉 Klik di bawah untuk melakukan pengecekan ulang atau menghapus riwayat:', {
                reply_markup: {
                    inline_keyboard: createHistoryButtons()  // Menggunakan fungsi yang sudah ada
                }
            });
        } else {
            bot.sendMessage(msg.chat.id, '❌ Belum ada riwayat pengecekan.');
        }
    } else {
        bot.sendMessage(msg.chat.id, '👍');
    }
});

// Menangani klik tombol riwayat pengecekan, pengecekan ulang, atau hapus riwayat
bot.on('callback_query', async (query) => {
    const { data, message } = query;

    try {
        // Segera jawab callback query untuk menghindari timeout
        await bot.answerCallbackQuery(query.id, { show_alert: true });

        if (data.startsWith('retry_')) {
            const index = parseInt(data.split('_')[1]);
            const entry = history[index];

            if (entry) {
                // Mengirimkan pesan bahwa pengecekan ulang sedang dilakukan
                bot.sendMessage(message.chat.id, `🔄 Melakukan pengecekan ulang untuk: ${entry.ne1} ↔ ${entry.ne2}...`);

                // Melakukan pengecekan ulang menggunakan NE Name yang ada di riwayat
                const result1 = await checkMetroStatus(entry.ne1, entry.ne2, { mode: 'normal' });
                const result2 = await checkMetroStatus(entry.ne2, entry.ne1, { mode: 'normal' });

                // Gabungkan hasil pengecekan ulang
                const combinedResult = result1 + '\n────────────\n' + result2;

                // Mengirimkan hasil pengecekan ulang
                bot.sendMessage(message.chat.id, `🔁 Pengecekan ulang selesai:\n\n${combinedResult}`);
            }
        }

        if (data.startsWith('delete_')) {
            const index = parseInt(data.split('_')[1]);
            const entry = history[index];

            if (entry) {
                // Hapus entry dari riwayat
                history.splice(index, 1);

                // Simpan perubahan ke file
                saveHistoryToFile();

                // Kirim pesan konfirmasi ke pengguna
                bot.sendMessage(message.chat.id, `✅ Riwayat pengecekan ${entry.shortNe1} ↔ ${entry.shortNe2} telah dihapus.`);
            }
        }
    } catch (error) {
        console.error('Error handling callback query:', error);
        bot.answerCallbackQuery(query.id, { text: '❌ Terjadi kesalahan saat memproses permintaan. Coba lagi!', show_alert: true });
    }
});
