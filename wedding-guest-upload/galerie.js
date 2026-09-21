// galerie.js — Gast-Galerie: laedt per URL-Parameter (?g=<code>) genau die
// Fotos, auf denen dieser Gast laut Gesichtserkennung zu sehen ist. Ohne
// gueltigen Code zeigt die Seite stattdessen ein Eingabefeld - ein
// einziger Link kann so an alle Gaeste gehen, der persoenliche Code kommt
// separat (siehe resolve-guest.php). Die eigentlichen Bild-/Videodateien
// werden nie kopiert, sondern live ueber image.php direkt vom NAS-Pfad
// gestreamt (siehe dort).

const params = new URLSearchParams(location.search);
let guest = params.get('g') || '';

const greetingEl = document.getElementById('greeting');
const subGreetingEl = document.getElementById('subGreeting');
const thankYouEl = document.getElementById('thankYou');
const stateMsgEl = document.getElementById('stateMsg');
const photoCountEl = document.getElementById('photoCount');
const gridEl = document.getElementById('grid');
const codeEntryEl = document.getElementById('codeEntry');
const codeFormEl = document.getElementById('codeForm');
const codeInputEl = document.getElementById('codeInput');
const codeErrorEl = document.getElementById('codeError');

function showState(msg, isError) {
  stateMsgEl.textContent = msg;
  stateMsgEl.hidden = false;
  stateMsgEl.classList.toggle('error', !!isError);
}

// Zeigt die Code-Eingabe statt einer Sackgassen-Fehlermeldung - sowohl
// beim allerersten Aufruf ohne ?g= (der eine Link, der an alle Gaeste
// geht) als auch wenn ein eingegebener Code nicht erkannt wurde (dann
// bleibt er im Feld stehen, damit man ihn direkt korrigieren kann statt
// neu zu tippen).
function showCodeEntry(errorMsg) {
  greetingEl.textContent = 'Deine Fotos';
  subGreetingEl.textContent = 'Gib deinen persönlichen Code ein, um deine Fotos zu sehen.';
  thankYouEl.hidden = true;
  stateMsgEl.hidden = true;
  photoCountEl.hidden = true;
  gridEl.hidden = true;
  codeEntryEl.hidden = false;
  codeErrorEl.hidden = !errorMsg;
  if (errorMsg) codeErrorEl.textContent = errorMsg;
  codeInputEl.focus();
}

codeFormEl.addEventListener('submit', (e) => {
  e.preventDefault();
  const code = codeInputEl.value.trim().toLowerCase().replace(/\s+/g, '');
  if (!code) return;
  location.href = `galerie.html?g=${encodeURIComponent(code)}`;
});

let photos = [];

async function load() {
  if (!guest) {
    showCodeEntry();
    return;
  }

  if (!/^[a-z0-9-]{1,60}$/.test(guest)) {
    codeInputEl.value = guest;
    showCodeEntry('Dieser Code scheint nicht zu stimmen. Bitte nochmal prüfen.');
    return;
  }

  showState('Einen Moment, wir laden eure Fotos …', false);

  let res, data;
  try {
    res = await fetch(`photos.php?g=${encodeURIComponent(guest)}`);
    data = await res.json();
  } catch (e) {
    showState('Die Fotos konnten gerade nicht geladen werden. Bitte später nochmal versuchen.', true);
    return;
  }

  if (res.status === 404) {
    codeInputEl.value = guest;
    showCodeEntry(data.error || 'Diesen Code kennen wir leider nicht. Bitte nochmal prüfen.');
    return;
  }
  if (!res.ok || data.error) {
    showState(data.error || 'Kein Gast mit diesem Code gefunden.', true);
    return;
  }

  codeEntryEl.hidden = true;
  photos = data.photos || [];
  greetingEl.textContent = `Für ${data.name}`;

  thankYouEl.innerHTML = '<p>Ihr und das Wetter habt uns an diesem Tag alles gegeben &ndash; danke von Herzen. ♥</p>'
    + '<p>Als kleines Dankeschön möchten wir euch etwas zurückgeben: hier sind eure Fotos. '
    + 'Die Galerie füllt sich nach und nach weiter – mit euren eigenen Uploads, und bald auch mit den Bildern unserer Fotografin.</p>';
  thankYouEl.hidden = false;

  if (photos.length === 0) {
    subGreetingEl.textContent = 'Bisher sind noch keine Fotos von dir dabei.';
    stateMsgEl.hidden = true;
    return;
  }

  subGreetingEl.textContent = 'Hier sind die Fotos, auf denen wir dich entdeckt haben.';
  stateMsgEl.hidden = true;
  photoCountEl.textContent = `${photos.length} ${photos.length === 1 ? 'Foto' : 'Fotos'}`;
  photoCountEl.hidden = false;

  renderGrid();
}

// Echtes, gedrosseltes Lazy-Loading statt des nativen loading="lazy": bei
// grossen Listen (z.B. 299 Fotos) laedt der Browser mit dem nativen
// Attribut immer noch weit mehr gleichzeitig an, als die schwache NAS an
// PHP-FPM-Workern gleichzeitig bedienen kann - fuehrte im Test zu
// reihenweise 500ern/Verbindungsabbruechen. Deshalb hier: IntersectionObserver
// setzt src erst kurz vor Sichtbarkeit, und eine kleine Warteschlange
// begrenzt zusaetzlich, wie viele Downloads wirklich gleichzeitig laufen.
const MAX_CONCURRENT_LOADS = 4;
let activeLoads = 0;
const loadQueue = [];

function queueLoad(startFn) {
  loadQueue.push(startFn);
  pumpQueue();
}
function pumpQueue() {
  while (activeLoads < MAX_CONCURRENT_LOADS && loadQueue.length > 0) {
    activeLoads++;
    const start = loadQueue.shift();
    start(() => { activeLoads--; pumpQueue(); });
  }
}

const lazyObserver = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const el = entry.target;
    lazyObserver.unobserve(el);
    queueLoad((done) => {
      const src = el.dataset.src;
      if (el.tagName === 'IMG') {
        el.addEventListener('load', done, { once: true });
        el.addEventListener('error', done, { once: true });
      } else {
        // Video: 'loadedmetadata' reicht als Ladeende (preload="metadata"),
        // wir laden hier keine volle Videodatei fuers Thumbnail.
        el.addEventListener('loadedmetadata', done, { once: true });
        el.addEventListener('error', done, { once: true });
      }
      el.src = src;
    });
  }
}, { rootMargin: '200px' });

function renderGrid() {
  gridEl.innerHTML = '';
  photos.forEach((p) => {
    const btn = document.createElement('button');
    btn.className = 'thumb';
    btn.setAttribute('aria-label', p.filename);
    btn.addEventListener('click', () => openLightbox(p.i));

    const src = `image.php?g=${encodeURIComponent(guest)}&i=${p.i}`;

    if (p.type === 'video') {
      const video = document.createElement('video');
      video.dataset.src = src;
      video.preload = 'none';
      video.muted = true;
      video.playsInline = true;
      btn.appendChild(video);
      lazyObserver.observe(video);
      const badge = document.createElement('span');
      badge.className = 'video-badge';
      badge.textContent = 'Video';
      btn.appendChild(badge);
      const play = document.createElement('span');
      play.className = 'play-icon';
      play.textContent = '▶';
      btn.appendChild(play);
    } else {
      const img = document.createElement('img');
      img.dataset.src = src;
      img.alt = '';
      btn.appendChild(img);
      lazyObserver.observe(img);
    }
    gridEl.appendChild(btn);
  });
  gridEl.hidden = false;
}

// ---------- Lightbox ----------
const lightboxEl = document.getElementById('lightbox');
const lbDownloadEl = document.getElementById('lbDownload');
let lbIndex = -1;

function openLightbox(photoIndex) {
  lbIndex = photos.findIndex((p) => p.i === photoIndex);
  showLightboxItem();
  lightboxEl.hidden = false;
}

function showLightboxItem() {
  const p = photos[lbIndex];
  const src = `image.php?g=${encodeURIComponent(guest)}&i=${p.i}`;

  // Fuer Videos ersetzen wir das <img> im DOM durch ein <video> (und
  // umgekehrt), statt beide Tags dauerhaft vorzuhalten - haelt die Logik
  // an einer Stelle statt zwei parallele Elemente synchron zu halten. Das
  // aktuelle Element wird jedesmal frisch per getElementById geholt (nicht
  // in einer Modul-Variable gecacht) - sonst zeigt eine so gecachte
  // Referenz nach dem ersten Tausch dauerhaft auf das inzwischen aus dem
  // DOM entfernte alte Element, und der naechste Vergleich vergleicht
  // gegen ein Element, das gar nicht mehr sichtbar ist.
  const isVideo = p.type === 'video';
  const tagName = isVideo ? 'VIDEO' : 'IMG';
  const current = document.getElementById('lightboxMedia');
  if (current.tagName !== tagName) {
    const replacement = document.createElement(tagName.toLowerCase());
    replacement.id = 'lightboxMedia';
    current.replaceWith(replacement);
  }
  const mediaEl = document.getElementById('lightboxMedia');
  mediaEl.src = src;
  if (isVideo) {
    mediaEl.controls = true;
    mediaEl.autoplay = true;
    mediaEl.playsInline = true;
  }

  lbDownloadEl.href = `image.php?g=${encodeURIComponent(guest)}&i=${p.i}&dl=1`;
  lbDownloadEl.setAttribute('download', p.filename);
}

document.getElementById('lbClose').addEventListener('click', () => { lightboxEl.hidden = true; });
document.getElementById('lbPrev').addEventListener('click', () => {
  lbIndex = (lbIndex - 1 + photos.length) % photos.length;
  showLightboxItem();
});
document.getElementById('lbNext').addEventListener('click', () => {
  lbIndex = (lbIndex + 1) % photos.length;
  showLightboxItem();
});
lightboxEl.addEventListener('click', (e) => {
  if (e.target === lightboxEl) lightboxEl.hidden = true;
});
document.addEventListener('keydown', (e) => {
  if (lightboxEl.hidden) return;
  if (e.key === 'Escape') lightboxEl.hidden = true;
  if (e.key === 'ArrowLeft') document.getElementById('lbPrev').click();
  if (e.key === 'ArrowRight') document.getElementById('lbNext').click();
});

load();
