// galerie.js — Gast-Galerie: laedt per URL-Parameter (?g=<slug>) genau die
// Fotos, auf denen dieser Gast laut Gesichtserkennung zu sehen ist. Die
// eigentlichen Bild-/Videodateien werden nie kopiert, sondern live ueber
// image.php direkt vom NAS-Pfad gestreamt (siehe dort).

const params = new URLSearchParams(location.search);
const guest = params.get('g') || '';

const greetingEl = document.getElementById('greeting');
const subGreetingEl = document.getElementById('subGreeting');
const stateMsgEl = document.getElementById('stateMsg');
const photoCountEl = document.getElementById('photoCount');
const gridEl = document.getElementById('grid');

function showState(msg, isError) {
  stateMsgEl.textContent = msg;
  stateMsgEl.hidden = false;
  stateMsgEl.classList.toggle('error', !!isError);
}

let photos = [];

async function load() {
  if (!/^[a-z0-9-]{1,60}$/.test(guest)) {
    subGreetingEl.textContent = 'Dieser Link scheint nicht vollständig zu sein.';
    showState('Kein gültiger Gast-Link gefunden. Bitte den Link nochmal prüfen, den du bekommen hast.', true);
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

  if (!res.ok || data.error) {
    showState(data.error || 'Kein Gast mit diesem Link gefunden.', true);
    return;
  }

  photos = data.photos || [];
  greetingEl.textContent = `Für ${data.name}`;

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

function renderGrid() {
  gridEl.innerHTML = '';
  photos.forEach((p) => {
    const btn = document.createElement('button');
    btn.className = 'thumb';
    btn.setAttribute('aria-label', p.filename);
    btn.addEventListener('click', () => openLightbox(p.i));

    if (p.type === 'video') {
      const video = document.createElement('video');
      video.src = `image.php?g=${encodeURIComponent(guest)}&i=${p.i}`;
      video.preload = 'metadata';
      video.muted = true;
      video.playsInline = true;
      btn.appendChild(video);
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
      img.loading = 'lazy';
      img.src = `image.php?g=${encodeURIComponent(guest)}&i=${p.i}`;
      img.alt = '';
      btn.appendChild(img);
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
