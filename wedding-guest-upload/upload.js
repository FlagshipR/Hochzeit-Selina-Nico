// upload.js — Chunked Upload mit Wiederaufnahme nach Abbruch, ohne externe
// Abhaengigkeiten (kein Uppy/tus noetig - siehe README, warum bewusst
// selbst geschrieben statt einer fertigen Bibliothek).
//
// Kern-Idee gegen Abbrueche: die fileId ist NICHT zufaellig, sondern aus
// Gast+Dateiname+Groesse abgeleitet (deterministisch). Waehlt ein Gast nach
// einem Verbindungsabbruch/Tab-Neuladen dieselben Dateien nochmal aus (Browser
// erlauben keinen Zugriff auf zuvor ausgewaehlte File-Objekte nach einem
// Reload), erkennt der Server anhand derselben fileId automatisch den
// bisherigen Fortschritt und es wird nur der fehlende Rest uebertragen -
// ohne dass Client oder Server sich Zustand ueber den Reload hinweg merken
// muessen.

const CHUNK_SIZE = 5 * 1024 * 1024; // 5 MB - muss mit upload.php uebereinstimmen
const MAX_RETRIES = 5;
const MAX_CONCURRENT_FILES = 2;
const ALLOWED_EXT = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'mp4', 'mov', 'm4v', '3gp'];
const NAME_STORAGE_KEY = 'wedding-guest-upload-name';

const els = {
  guestName: document.getElementById('guestName'),
  fileInput: document.getElementById('fileInput'),
  dropZone: document.getElementById('dropZone'),
  fileList: document.getElementById('fileList'),
  retryAllBtn: document.getElementById('retryAllBtn'),
};

let queue = [];
let activeUploads = 0;

init();

function init() {
  const savedName = localStorage.getItem(NAME_STORAGE_KEY);
  if (savedName) els.guestName.value = savedName;
  els.guestName.addEventListener('input', () => {
    localStorage.setItem(NAME_STORAGE_KEY, els.guestName.value.trim());
  });

  els.fileInput.addEventListener('change', () => {
    addFiles(Array.from(els.fileInput.files));
    els.fileInput.value = '';
  });

  ['dragover', 'dragleave', 'drop'].forEach(evt => {
    els.dropZone.addEventListener(evt, e => e.preventDefault());
  });
  els.dropZone.addEventListener('dragover', () => els.dropZone.classList.add('drag'));
  els.dropZone.addEventListener('dragleave', () => els.dropZone.classList.remove('drag'));
  els.dropZone.addEventListener('drop', e => {
    els.dropZone.classList.remove('drag');
    addFiles(Array.from(e.dataTransfer.files));
  });

  els.retryAllBtn.addEventListener('click', () => {
    queue.filter(f => f.status === 'error').forEach(f => startUpload(f));
  });
}

function addFiles(files) {
  const guest = els.guestName.value.trim();
  if (!guest) {
    alert('Bitte zuerst deinen Namen eintragen, dann Fotos/Videos auswaehlen.');
    return;
  }
  for (const file of files) {
    const ext = (file.name.split('.').pop() || '').toLowerCase();
    if (!ALLOWED_EXT.includes(ext)) continue; // stille Filterung, z.B. .DS_Store beim Mehrfachauswaehlen

    const entry = {
      file,
      guest,
      filename: file.name,
      totalSize: file.size,
      uploadedBytes: 0,
      status: 'waiting',
      errorMsg: '',
      row: null,
      fileId: null,
    };
    queue.push(entry);
    renderRow(entry);
    computeFileId(entry).then(() => scheduleUpload(entry));
  }
}

async function computeFileId(entry) {
  // Deterministisch aus Gast+Dateiname+Groesse, nicht zufaellig - siehe
  // Datei-Kommentar oben. SHA-256 nur, damit ein beliebiger Dateiname sicher
  // als Dateiname der Zwischendatei auf dem Server verwendet werden kann.
  const raw = `${entry.guest}|${entry.filename}|${entry.totalSize}`;
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(raw));
  entry.fileId = Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

function scheduleUpload(entry) {
  if (activeUploads < MAX_CONCURRENT_FILES) {
    startUpload(entry);
  } else {
    entry.status = 'waiting';
    updateRow(entry);
  }
}

async function startUpload(entry) {
  activeUploads++;
  entry.status = 'uploading';
  entry.errorMsg = '';
  updateRow(entry);

  try {
    // Serverstand abfragen statt blind bei 0 zu starten - traegt die
    // Wiederaufnahme nach einem Abbruch/Reload (siehe Datei-Kommentar oben).
    entry.uploadedBytes = await getServerOffset(entry.fileId);
    updateRow(entry);

    while (entry.uploadedBytes < entry.totalSize) {
      const chunkIndex = Math.floor(entry.uploadedBytes / CHUNK_SIZE);
      // Chunk-Grenzen richten sich nach dem Server-Offset, nicht nach einem
      // fortlaufenden Zaehler - falls der Server schon mehr hat als ein
      // exaktes Vielfaches von CHUNK_SIZE (sollte nicht vorkommen, aber
      // sicherheitshalber), wird trotzdem am richtigen Byte weitergemacht.
      const start = chunkIndex * CHUNK_SIZE;
      const end = Math.min(start + CHUNK_SIZE, entry.totalSize);
      const blob = entry.file.slice(start, end);

      const newOffset = await uploadChunkWithRetry(entry, chunkIndex, blob);
      entry.uploadedBytes = newOffset;
      updateRow(entry);
    }

    entry.status = 'done';
    updateRow(entry);
  } catch (err) {
    entry.status = 'error';
    entry.errorMsg = err && err.message ? err.message : 'Unbekannter Fehler';
    updateRow(entry);
  } finally {
    activeUploads--;
    const next = queue.find(f => f.status === 'waiting' && f.fileId);
    if (next) startUpload(next);
  }
}

async function uploadChunkWithRetry(entry, chunkIndex, blob) {
  let lastErr;
  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    try {
      const params = new URLSearchParams({
        action: 'chunk',
        fileId: entry.fileId,
        guest: entry.guest,
        filename: entry.filename,
        chunkIndex: String(chunkIndex),
        totalSize: String(entry.totalSize),
      });
      const res = await fetch(`upload.php?${params}`, { method: 'POST', body: blob });
      if (!res.ok) {
        const body = await res.json().catch(() => ({}));
        throw new Error(body.error || `Server-Fehler (${res.status})`);
      }
      const data = await res.json();
      return data.bytesReceived;
    } catch (err) {
      lastErr = err;
      // Exponentielles Backoff: gerade bei einer schlechten Verbindung soll
      // nicht sofort wieder gegen dieselbe Wand gefahren werden.
      await sleep(Math.min(1000 * 2 ** attempt, 15000));
    }
  }
  throw lastErr;
}

async function getServerOffset(fileId) {
  const res = await fetch(`upload.php?action=status&fileId=${fileId}`);
  if (!res.ok) throw new Error('Status konnte nicht abgefragt werden');
  const data = await res.json();
  return data.bytesReceived;
}

function sleep(ms) {
  return new Promise(r => setTimeout(r, ms));
}

function renderRow(entry) {
  const row = document.createElement('div');
  row.className = 'file-row';
  row.innerHTML = `
    <div class="file-name"></div>
    <div class="file-progress"><div class="file-progress-bar"></div></div>
    <div class="file-status"></div>
  `;
  row.querySelector('.file-name').textContent = entry.filename;
  els.fileList.prepend(row);
  entry.row = row;
  updateRow(entry);
}

function updateRow(entry) {
  if (!entry.row) return;
  const pct = entry.totalSize ? Math.round((entry.uploadedBytes / entry.totalSize) * 100) : 0;
  entry.row.querySelector('.file-progress-bar').style.width = pct + '%';
  const statusEl = entry.row.querySelector('.file-status');
  entry.row.classList.remove('is-done', 'is-error');
  if (entry.status === 'done') {
    statusEl.textContent = 'Fertig ✓';
    entry.row.classList.add('is-done');
  } else if (entry.status === 'error') {
    statusEl.textContent = 'Fehler – ' + entry.errorMsg;
    entry.row.classList.add('is-error');
  } else if (entry.status === 'waiting') {
    statusEl.textContent = 'Wartet…';
  } else {
    statusEl.textContent = pct + '%';
  }
  els.retryAllBtn.hidden = !queue.some(f => f.status === 'error');
}
