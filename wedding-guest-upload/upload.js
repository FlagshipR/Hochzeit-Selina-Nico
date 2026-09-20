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
//
// Ablauf bewusst zweistufig (Design-Ueberarbeitung): Dateien auswaehlen ->
// Vorschau/Zusammenfassung ansehen -> erst per "Erinnerungen senden" wird
// tatsaechlich hochgeladen. Vorher startete der Upload sofort bei Auswahl -
// das gab keine Gelegenheit, die Auswahl nochmal zu pruefen.

const CHUNK_SIZE = 5 * 1024 * 1024; // 5 MB - muss mit upload.php uebereinstimmen
const MAX_RETRIES = 5;
const MAX_CONCURRENT_FILES = 2;
const ALLOWED_EXT = ['jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'mp4', 'mov', 'm4v', '3gp'];
const VIDEO_EXT = ['mp4', 'mov', 'm4v', '3gp'];
const NAME_STORAGE_KEY = 'wedding-guest-upload-name';

const els = {
  guestName: document.getElementById('guestName'),
  fileInput: document.getElementById('fileInput'),
  chooseFilesBtn: document.getElementById('chooseFilesBtn'),
  dropZone: document.getElementById('dropZone'),
  fileList: document.getElementById('fileList'),
  uploadSummary: document.getElementById('uploadSummary'),
  submitBtn: document.getElementById('submitBtn'),
  retryAllBtn: document.getElementById('retryAllBtn'),
  successMsg: document.getElementById('successMsg'),
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

  els.chooseFilesBtn.addEventListener('click', () => els.fileInput.click());
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

  els.submitBtn.addEventListener('click', () => {
    els.submitBtn.hidden = true;
    queue.filter(f => f.status === 'waiting').forEach(scheduleUpload);
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
      thumbEl: null,
      fileId: null,
      isVideo: VIDEO_EXT.includes(ext),
    };
    queue.push(entry);
    renderThumb(entry);
    computeFileId(entry);
  }
  updateSummary();
}

function computeFileId(entry) {
  // Deterministisch aus Gast+Dateiname+Groesse, nicht zufaellig - siehe
  // Datei-Kommentar oben. Bewusst KEIN crypto.subtle (Web Crypto API): die
  // ist nur in "sicheren Kontexten" verfuegbar (https:// oder localhost) -
  // beim Testen ueber die blanke NAS-IP (http://192.168.178.21:8081, kein
  // https, kein localhost) ist sie undefined, crypto.subtle.digest() wirft
  // dann und die Datei blieb lautlos fuer immer bei "Wartet". Eine simple
  // FNV-1a-Hashfunktion braucht keine Secure-Context-Freigabe und muss hier
  // auch nicht kryptographisch sicher sein - dient nur als stabile ID zur
  // Wiederaufnahme-Erkennung, nicht als Sicherheitsgrenze.
  const raw = `${entry.guest}|${entry.filename}|${entry.totalSize}`;
  let hash = 0x811c9dc5;
  for (let i = 0; i < raw.length; i++) {
    hash ^= raw.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193);
  }
  entry.fileId = (hash >>> 0).toString(16).padStart(8, '0');
}

function scheduleUpload(entry) {
  if (activeUploads < MAX_CONCURRENT_FILES) {
    startUpload(entry);
  } else {
    entry.status = 'waiting';
    updateThumb(entry);
  }
}

async function startUpload(entry) {
  activeUploads++;
  entry.status = 'uploading';
  entry.errorMsg = '';
  updateThumb(entry);

  try {
    // Serverstand abfragen statt blind bei 0 zu starten - traegt die
    // Wiederaufnahme nach einem Abbruch/Reload (siehe Datei-Kommentar oben).
    entry.uploadedBytes = await getServerOffset(entry.fileId);
    updateThumb(entry);

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
      updateThumb(entry);
    }

    entry.status = 'done';
    updateThumb(entry);
  } catch (err) {
    entry.status = 'error';
    entry.errorMsg = err && err.message ? err.message : 'Unbekannter Fehler';
    updateThumb(entry);
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

function formatSize(bytes) {
  const mb = bytes / (1024 * 1024);
  return mb >= 1000 ? `${(mb / 1024).toFixed(1)} GB` : `${Math.round(mb)} MB`;
}

function updateSummary() {
  const count = queue.length;
  els.uploadSummary.hidden = count === 0;
  els.submitBtn.hidden = count === 0 || !queue.some(f => f.status === 'waiting');
  if (count === 0) return;
  const totalBytes = queue.reduce((sum, f) => sum + f.totalSize, 0);
  els.uploadSummary.textContent = `${count} ${count === 1 ? 'Datei' : 'Dateien'} ausgewählt · ${formatSize(totalBytes)}`;
}

function renderThumb(entry) {
  const thumb = document.createElement('div');
  thumb.className = 'thumb';

  if (entry.isVideo) {
    const video = document.createElement('video');
    video.src = URL.createObjectURL(entry.file);
    video.muted = true;
    video.preload = 'metadata';
    thumb.appendChild(video);
    const badge = document.createElement('span');
    badge.className = 'video-badge';
    badge.textContent = '▶ Video';
    thumb.appendChild(badge);
  } else {
    const img = document.createElement('img');
    img.src = URL.createObjectURL(entry.file);
    img.alt = entry.filename;
    thumb.appendChild(img);
  }

  const progress = document.createElement('div');
  progress.className = 'thumb-progress';
  progress.innerHTML = '<div class="thumb-progress-bar"></div>';
  thumb.appendChild(progress);

  const status = document.createElement('div');
  status.className = 'thumb-status';
  thumb.appendChild(status);

  els.fileList.appendChild(thumb);
  entry.thumbEl = thumb;
  updateThumb(entry);
}

function updateThumb(entry) {
  if (!entry.thumbEl) return;
  const pct = entry.totalSize ? Math.round((entry.uploadedBytes / entry.totalSize) * 100) : 0;
  entry.thumbEl.querySelector('.thumb-progress-bar').style.width = pct + '%';
  const statusEl = entry.thumbEl.querySelector('.thumb-status');
  entry.thumbEl.classList.remove('is-done', 'is-error');
  if (entry.status === 'done') {
    statusEl.textContent = '✓';
    entry.thumbEl.classList.add('is-done');
  } else if (entry.status === 'error') {
    statusEl.textContent = '✗';
    entry.thumbEl.title = entry.errorMsg;
    entry.thumbEl.classList.add('is-error');
  } else {
    statusEl.textContent = '';
  }
  els.retryAllBtn.hidden = !queue.some(f => f.status === 'error');
  updateSummary();
  checkAllDone();
}

function checkAllDone() {
  if (queue.length === 0) return;
  const allDone = queue.every(f => f.status === 'done');
  els.successMsg.hidden = !allDone;
}
