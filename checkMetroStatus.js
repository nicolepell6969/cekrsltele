const puppeteer = require('puppeteer');

// Fungsi untuk mengubah NE Name menjadi kapital
function toUpperCaseNEName(neName) {
    return neName.toUpperCase();
}

// Fungsi untuk mendapatkan emoji status RX Level
function getRxLevelStatusEmoji(rxLevel, rxThreshold) {
    if (rxLevel === '-40.00') {
        return '❌'; // RX Level -40 dBm berarti ada error atau masalah
    }

    const rxValue = parseFloat(rxLevel);
    const thresholdValue = parseFloat(rxThreshold);
    
    if (rxValue > thresholdValue) {
        return '✅'; // Status stabil karena di bawah threshold
    }
    
    return '⚠️'; // Status tidak stabil karena di atas threshold
}

async function checkMetroStatus(neName1, neName2, options = {}) {
  const mode = options.mode || 'normal'; // 'normal', 'summary', 'full', 'with_opposite'
  
  const browser = await puppeteer.launch({ 
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });
  const page = await browser.newPage();

  try {
    // Ubah NE Name menjadi kapital sebelum dikirim
    neName1 = toUpperCaseNEName(neName1);
    neName2 = toUpperCaseNEName(neName2);

    console.log(`Mengakses halaman web untuk NE: ${neName1} dan ${neName2}...`);
    await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
      waitUntil: 'domcontentloaded',
      timeout: 30000
    });

    // Isi formulir dengan NE pertama
    await page.type('input[name="nename"]', neName1);
    await page.select('select[name="service"]', 'rx-level');
    await page.click('input[name="submit"]');
    
    // Tunggu iframe untuk memuat hasil
    await page.waitForSelector('iframe#myIframe', { timeout: 10000 });
    
    // Dapatkan URL iframe dan buka untuk memuat hasil
    const frameUrl = await page.evaluate(() => {
      const iframe = document.querySelector('iframe#myIframe');
      return iframe ? iframe.src : null;
    });

    const framePage = await browser.newPage();
    await framePage.goto(frameUrl, { waitUntil: 'networkidle2', timeout: 60000 });

    // Ambil data dari tabel yang ada di halaman iframe
    const result = await framePage.evaluate(() => {
      const tables = document.querySelectorAll('table');
      if (tables.length === 0) return [];

      let allResults = [];
      const wantedColumns = ['NE Name', 'Description', 'RX Level', 'RX Threshold', 'Oper Status', 'Interface', 'IF Speed', 'NE IP'];

      for (const table of tables) {
        const rows = table.querySelectorAll('tr');
        let columnIndices = {};
        let headerRow = null;
        
        for (const row of rows) {
          const cells = row.querySelectorAll('th, td');
          if (cells.length > 0) {
            for (let i = 0; i < cells.length; i++) {
              const cellText = cells[i].textContent.trim();
              wantedColumns.forEach(col => {
                if (cellText.toLowerCase().includes(col.toLowerCase())) {
                  columnIndices[col] = i;
                  headerRow = row;
                }
              });
            }
            
            if (Object.keys(columnIndices).length > 0) {
              break;
            }
          }
        }
        
        if (Object.keys(columnIndices).length === 0) continue;
        
        for (const row of rows) {
          if (row === headerRow) continue;
          
          const cells = row.querySelectorAll('td');
          if (cells.length > 0) {
            let rowData = {};
            let hasData = false;
            
            for (const [colName, colIndex] of Object.entries(columnIndices)) {
              if (colIndex < cells.length) {
                const value = cells[colIndex].textContent.trim();
                if (value) {
                  rowData[colName] = value;
                  hasData = true;
                }
              }
            }
            
            if (hasData) {
              rowData['IP Address'] = rowData['IP Address'] || 'N/A';
              rowData['Port'] = rowData['Port'] || 'N/A';
              rowData['TX Level'] = rowData['TX Level'] || 'N/A';
              rowData['Connection'] = rowData['Connection'] || 'N/A';
              allResults.push(rowData);
            }
          }
        }
      }
      
      return allResults;
    });

    // Filter hasil yang relevan berdasarkan Description
    const filteredResults = result.filter(item => {
      const description = item['Description'] || '';
      return description.includes(neName1) || description.includes(neName2);
    });

    console.log(`Hasil yang relevan: ${filteredResults.length} entri`);

    await browser.close();

    // Format hasil sesuai dengan yang diinginkan
    return formatResults(filteredResults);

  } catch (error) {
    console.error(`Error: ${error.message}`);
    await browser.close();
    return `❌ Gagal memeriksa RX Level\nError: ${error.message}`;
  }
}

// Fungsi untuk memformat hasil menjadi lebih mudah dibaca
function formatResults(results) {
  if (results.length === 0) {
    return `❌ Tidak ada data yang relevan`;
  }

  let formattedResult = '';
  results.forEach((item) => {
    const rxLevelStatusEmoji = getRxLevelStatusEmoji(item['RX Level'], item['RX Threshold']);
    formattedResult += `▶️ ${item['NE IP']} | ${item['NE Name']} | ${item['Interface']} | ${item['IF Speed']} | ${item['Description']} | ${item['RX Level']} | ${item['RX Threshold']} | ${item['Oper Status']} ${rxLevelStatusEmoji}\n`;
  });

  return formattedResult;
}

// Ekspor fungsi checkMetroStatus agar bisa digunakan di file lain
module.exports = checkMetroStatus;
