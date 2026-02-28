// The full HTML string for the web dashboard served at http://<device-ip>:8080/
// ignore_for_file: unnecessary_string_escapes
const String dashboardHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>LAN Video &amp; OCR Server</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  :root{
    --bg:#0d1117;--surface:#161b22;--border:#30363d;
    --accent:#58a6ff;--text:#e6edf3;--sub:#8b949e;
    --ok:#3fb950;--warn:#d29922;--err:#f85149;
    --btn-cap:#238636;--btn-ocr:#1f6feb;--btn-copy-img:#6e40c9;
  }
  body{background:var(--bg);color:var(--text);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;min-height:100vh;display:flex;flex-direction:column}
  header{background:var(--surface);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
  header h1{font-size:1.15rem;font-weight:600;letter-spacing:.3px;flex:1}
  .pill{font-size:.74rem;font-weight:600;padding:3px 10px;border-radius:999px;letter-spacing:.5px;white-space:nowrap}
  .pill.ok  {background:#1a3a22;color:var(--ok);  border:1px solid #2ea04326}
  .pill.warn{background:#3a3000;color:var(--warn);border:1px solid #d2992226}
  .pill.err {background:#3a1a1a;color:var(--err); border:1px solid #f8514926}
  main{flex:1;display:grid;grid-template-columns:1fr 1fr;gap:16px;padding:20px;max-width:1600px;width:100%;margin:0 auto}
  @media(max-width:900px){main{grid-template-columns:1fr}}
  .card{background:var(--surface);border:1px solid var(--border);border-radius:10px;overflow:hidden;display:flex;flex-direction:column}
  .card-header{padding:12px 16px;border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap}
  .card-header h2{font-size:.9rem;font-weight:600;color:var(--sub);text-transform:uppercase;letter-spacing:.8px}
  .card-header .meta{font-size:.75rem;color:var(--sub)}
  .card-header .actions{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
  #videoWrap,#photoWrap{flex:1;display:flex;align-items:center;justify-content:center;background:#000;min-height:220px;position:relative}
  #videoStream,#photoImg{max-width:100%;max-height:65vh;object-fit:contain;display:block}
  #photoImg{display:none}
  #photoPlaceholder{color:var(--sub);font-style:italic;font-size:.9rem;padding:20px;text-align:center}
  #fpsEl{position:absolute;bottom:8px;right:10px;font-size:.72rem;color:#fff;background:rgba(0,0,0,.55);padding:2px 7px;border-radius:4px;pointer-events:none}
  .ocr-section{border-top:1px solid var(--border)}
  .ocr-header{padding:12px 16px;display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap}
  .ocr-header h2{font-size:.9rem;font-weight:600;color:var(--sub);text-transform:uppercase;letter-spacing:.8px}
  .ocr-header .actions{display:flex;gap:8px;align-items:center}
  .text-body{padding:16px;overflow-y:auto;max-height:220px}
  #ocrText{font-size:.9rem;line-height:1.65;white-space:pre-wrap;word-break:break-word;color:var(--text)}
  .placeholder{color:var(--sub)!important;font-style:italic}
  .btn{border:none;padding:7px 16px;border-radius:6px;font-size:.82rem;font-weight:600;cursor:pointer;transition:opacity .15s,transform .1s;display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
  .btn:active{transform:scale(.96);opacity:.85}
  .btn:disabled{opacity:.45;cursor:not-allowed;transform:none}
  .btn-capture     {background:var(--btn-cap);    color:#fff}
  .btn-capture:hover:not(:disabled){opacity:.88}
  .btn-ocr         {background:var(--btn-ocr);    color:#fff}
  .btn-ocr:hover:not(:disabled){opacity:.88}
  .btn-copy-text   {background:var(--accent);     color:#0d1117}
  .btn-copy-text:hover:not(:disabled){opacity:.85}
  .btn-copy-img    {background:var(--btn-copy-img);color:#fff}
  .btn-copy-img:hover:not(:disabled){opacity:.85}
  footer{text-align:center;padding:12px;color:var(--sub);font-size:.78rem;border-top:1px solid var(--border)}
  .spinner{width:14px;height:14px;border:2px solid rgba(255,255,255,.35);border-top-color:rgba(255,255,255,.9);border-radius:50%;animation:spin .7s linear infinite;display:none}
  .spinner.show{display:inline-block}
  @keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<header>
  <h1>&#128247; LAN Video &amp; OCR Server</h1>
  <span id="videoStatus" class="pill warn">Video: Connecting…</span>
  <span id="photoStatus" class="pill warn">Photo: None</span>
  <span id="textStatus"  class="pill warn">OCR: Ready</span>
</header>
<main>
  <!-- ── Left: Live camera feed ────────────────────────────────────────── -->
  <div class="card">
    <div class="card-header">
      <h2>Live Camera Feed</h2>
      <div class="actions">
        <span class="meta" id="resEl"></span>
        <button class="btn btn-capture" id="captureBtn" onclick="capturePhoto()">
          &#128247; Capture Photo
          <span class="spinner" id="capSpinner"></span>
        </button>
      </div>
    </div>
    <div id="videoWrap">
      <img id="videoStream" alt="Connecting…"/>
      <div id="fpsEl">-- fps</div>
    </div>
  </div>

  <!-- ── Right: Captured photo + OCR ──────────────────────────────────── -->
  <div class="card">
    <div class="card-header">
      <h2>Captured Photo</h2>
      <div class="actions">
        <button class="btn btn-copy-img" id="copyImgBtn" onclick="copyPhotoToClipboard()" disabled>
          &#128203; Copy Image
        </button>
        <button class="btn btn-ocr" id="ocrBtn" onclick="runOcr()" disabled>
          &#128269; Run OCR
          <span class="spinner" id="ocrSpinner"></span>
        </button>
      </div>
    </div>
    <div id="photoWrap">
      <div id="photoPlaceholder">Press "Capture Photo" to take a high-quality image</div>
      <img id="photoImg" alt="Captured"/>
    </div>

    <!-- OCR output section -->
    <div class="ocr-section">
      <div class="ocr-header">
        <h2>Extracted Text</h2>
        <div class="actions">
          <button class="btn btn-copy-text" id="copyTextBtn" onclick="copyTextToClipboard()" disabled>
            Copy Text
          </button>
        </div>
      </div>
      <div class="text-body">
        <div id="ocrText" class="placeholder">Run OCR to extract text from the captured photo…</div>
      </div>
    </div>
  </div>
</main>
<footer>Served by Flutter &bull; dart:io HttpServer &bull; WebSocket video + on-demand capture &amp; OCR</footer>

<script>
(function(){
  'use strict';

  // ── DOM refs ────────────────────────────────────────────────────────────
  const imgEl       = document.getElementById('videoStream');
  const photoEl     = document.getElementById('photoImg');
  const photoWrap   = document.getElementById('photoPlaceholder');
  const fpsEl       = document.getElementById('fpsEl');
  const resEl       = document.getElementById('resEl');
  const ocrEl       = document.getElementById('ocrText');
  const vStatusEl   = document.getElementById('videoStatus');
  const pStatusEl   = document.getElementById('photoStatus');
  const tStatusEl   = document.getElementById('textStatus');
  const captureBtn  = document.getElementById('captureBtn');
  const ocrBtn      = document.getElementById('ocrBtn');
  const copyImgBtn  = document.getElementById('copyImgBtn');
  const copyTextBtn = document.getElementById('copyTextBtn');
  const capSpinner  = document.getElementById('capSpinner');
  const ocrSpinner  = document.getElementById('ocrSpinner');

  // ── Helpers ─────────────────────────────────────────────────────────────
  function setPill(el, state, label){ el.textContent = label; el.className = 'pill ' + state; }

  function flashBtn(btn, msg, duration = 2200) {
    const orig = btn.textContent;
    btn.textContent = msg;
    setTimeout(() => { btn.textContent = orig; }, duration);
  }

  // ── FPS counter ─────────────────────────────────────────────────────────
  let frameCount = 0, lastFpsTime = performance.now();
  function tickFps(){
    frameCount++;
    const now = performance.now();
    if(now - lastFpsTime >= 1000){
      fpsEl.textContent = (frameCount * 1000 / (now - lastFpsTime)).toFixed(1) + ' fps';
      frameCount = 0; lastFpsTime = now;
    }
  }

  // ── Video WebSocket ─────────────────────────────────────────────────────
  let prevBlobUrl = null, firstFrame = true;
  function connectVideo(){
    const ws = new WebSocket('ws://' + location.host + '/ws/video');
    ws.binaryType = 'arraybuffer';
    ws.onopen  = () => setPill(vStatusEl, 'ok',   'Video: Live');
    ws.onerror = () => setPill(vStatusEl, 'err',  'Video: Error');
    ws.onclose = () => {
      setPill(vStatusEl, 'warn', 'Video: Reconnecting…');
      setTimeout(connectVideo, 1500);
    };
    ws.onmessage = (e) => {
      const blob = new Blob([e.data], {type:'image/jpeg'});
      const url  = URL.createObjectURL(blob);
      if(firstFrame){
        createImageBitmap(blob)
          .then(bm => { resEl.textContent = bm.width + '×' + bm.height; bm.close(); })
          .catch(()=>{});
        firstFrame = false;
      }
      const old = prevBlobUrl;
      imgEl.src = url; prevBlobUrl = url;
      if(old) URL.revokeObjectURL(old);
      tickFps();
    };
  }

  // ── Photo WebSocket ─────────────────────────────────────────────────────
  let currentPhotoBlobUrl = null;

  function connectPhoto(){
    const ws = new WebSocket('ws://' + location.host + '/ws/photo');
    ws.binaryType = 'arraybuffer';
    ws.onclose = () => setTimeout(connectPhoto, 1500);
    ws.onmessage = (e) => {
      const blob = new Blob([e.data], {type:'image/jpeg'});
      const url  = URL.createObjectURL(blob);
      const old  = currentPhotoBlobUrl;
      photoEl.src = url;
      currentPhotoBlobUrl = url;
      if(old) URL.revokeObjectURL(old);

      photoEl.style.display  = 'block';
      photoWrap.style.display = 'none';
      setPill(pStatusEl, 'ok', 'Photo: Ready');

      ocrBtn.disabled     = false;
      copyImgBtn.disabled = false;

      // Reset OCR output when a new photo arrives
      ocrEl.textContent = 'Run OCR to extract text from the captured photo…';
      ocrEl.className   = 'placeholder';
      copyTextBtn.disabled = true;
    };
  }

  // ── Text/OCR WebSocket ──────────────────────────────────────────────────
  function connectText(){
    const ws = new WebSocket('ws://' + location.host + '/ws/text');
    ws.onopen  = () => setPill(tStatusEl, 'ok', 'OCR: Ready');
    ws.onerror = () => setPill(tStatusEl, 'err', 'OCR: Error');
    ws.onclose = () => {
      setPill(tStatusEl, 'warn', 'OCR: Reconnecting…');
      setTimeout(connectText, 1500);
    };
    ws.onmessage = (e) => {
      setPill(tStatusEl, 'ok', 'OCR: Done');
      ocrEl.classList.remove('placeholder');
      ocrEl.textContent = e.data;
      copyTextBtn.disabled = false;
    };
  }

  connectVideo();
  connectPhoto();
  connectText();

  // ── Actions ─────────────────────────────────────────────────────────────

  /** Triggers a high-quality photo capture on the device. */
  window.capturePhoto = async function(){
    captureBtn.disabled = true;
    capSpinner.classList.add('show');
    try {
      const res = await fetch('/cmd/capture', {method: 'POST'});
      if(!res.ok) throw new Error('HTTP ' + res.status);
      setPill(pStatusEl, 'warn', 'Photo: Receiving…');
    } catch(err) {
      setPill(pStatusEl, 'err', 'Capture failed');
      console.error('capturePhoto:', err);
    } finally {
      captureBtn.disabled = false;
      capSpinner.classList.remove('show');
    }
  };

  /** Triggers OCR on the last captured photo on the device. */
  window.runOcr = async function(){
    ocrBtn.disabled = true;
    ocrSpinner.classList.add('show');
    setPill(tStatusEl, 'warn', 'OCR: Running…');
    ocrEl.textContent = 'Processing…';
    ocrEl.className   = 'placeholder';
    copyTextBtn.disabled = true;
    try {
      const res = await fetch('/cmd/ocr', {method: 'POST'});
      if(!res.ok) throw new Error('HTTP ' + res.status);
    } catch(err) {
      setPill(tStatusEl, 'err', 'OCR failed');
      ocrEl.textContent = 'OCR failed. Please try again.';
      console.error('runOcr:', err);
    } finally {
      ocrBtn.disabled = false;
      ocrSpinner.classList.remove('show');
    }
  };

  /** Copies the captured photo to the OS clipboard as an image. */
  window.copyPhotoToClipboard = async function(){
    if(!currentPhotoBlobUrl){ return; }
    copyImgBtn.disabled = true;
    try {
      const response = await fetch(currentPhotoBlobUrl);
      const blob     = await response.blob();
      // Clipboard API requires image/png; convert via OffscreenCanvas if needed.
      let finalBlob = blob;
      if(blob.type !== 'image/png'){
        const bmp    = await createImageBitmap(blob);
        const canvas = new OffscreenCanvas(bmp.width, bmp.height);
        const ctx    = canvas.getContext('2d');
        ctx.drawImage(bmp, 0, 0);
        bmp.close();
        finalBlob = await canvas.convertToBlob({type: 'image/png'});
      }
      await navigator.clipboard.write([
        new ClipboardItem({'image/png': finalBlob})
      ]);
      flashBtn(copyImgBtn, '&#128203; Copied ✓');
    } catch(err) {
      flashBtn(copyImgBtn, 'Failed');
      console.error('copyPhotoToClipboard:', err);
    } finally {
      copyImgBtn.disabled = false;
    }
  };

  /** Copies the OCR extracted text to the OS clipboard. */
  window.copyTextToClipboard = function(){
    const txt = ocrEl.textContent;
    if(!txt || ocrEl.classList.contains('placeholder')) return;
    navigator.clipboard.writeText(txt)
      .then(() => flashBtn(copyTextBtn, 'Copied ✓'))
      .catch(() => flashBtn(copyTextBtn, 'Failed'));
  };

})();
</script>
</body>
</html>
''';
