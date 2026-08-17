<!DOCTYPE html>
<!--
  Phase 6 frontend — a single self-contained HTML file (no build step, no
  external dependencies besides an optional Google Fonts stylesheet, which
  degrades gracefully to the system font stack if unreachable) that uploads
  a video straight to S3 via a pre-signed URL, then polls the web_api
  Lambda's /status/{job_id} route to animate the Step Functions execution's
  state transitions live.

  This file is a Terraform templatefile() SOURCE (terraform/modules/web/
  main.tf), not something you open directly -- the API_BASE constant in the
  script below is a template placeholder that gets substituted with the
  real, deployed API Gateway invoke URL at apply time. The rendered copy
  (with that URL baked in) is what actually gets uploaded to the frontend
  S3 bucket as index.html.
-->
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>AWS Step Functions Video Pipeline — Live Demo</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>🎬</text></svg>" />
<link rel="preconnect" href="https://fonts.googleapis.com" />
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet" />
<style>
  :root {
    --pending: #3a4560;
    --running: #4f8cff;
    --running-glow: rgba(79, 140, 255, 0.35);
    --succeeded: #2fd67f;
    --succeeded-glow: rgba(47, 214, 127, 0.3);
    --failed: #ff5470;
    --failed-glow: rgba(255, 84, 112, 0.3);
    --bg-0: #060a17;
    --bg-1: #0b1224;
    --card: rgba(22, 30, 54, 0.72);
    --card-solid: #141b34;
    --border: rgba(148, 163, 184, 0.14);
    --border-strong: rgba(148, 163, 184, 0.28);
    --text: #eef1fb;
    --muted: #8b93b0;
    --accent-a: #6d5bff;
    --accent-b: #3ec6ff;
  }

  * { box-sizing: border-box; }

  html { scroll-behavior: smooth; }

  body {
    margin: 0;
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    color: var(--text);
    min-height: 100vh;
    padding: 3rem 1.25rem 5rem;
    background:
      radial-gradient(60rem 40rem at 12% -10%, rgba(109, 91, 255, 0.22), transparent 60%),
      radial-gradient(50rem 35rem at 110% 10%, rgba(62, 198, 255, 0.16), transparent 55%),
      radial-gradient(40rem 30rem at 50% 120%, rgba(47, 214, 127, 0.10), transparent 60%),
      linear-gradient(180deg, var(--bg-0), var(--bg-1) 45%, var(--bg-0));
    background-attachment: fixed;
  }

  .wrap { max-width: 760px; margin: 0 auto; }

  .hero { margin-bottom: 2.2rem; }
  .eyebrow {
    display: inline-flex; align-items: center; gap: 0.4rem;
    font-size: 0.72rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase;
    color: var(--accent-b);
    background: rgba(62, 198, 255, 0.1);
    border: 1px solid rgba(62, 198, 255, 0.25);
    padding: 0.3rem 0.7rem;
    border-radius: 999px;
    margin-bottom: 1rem;
  }
  .eyebrow .pulse-dot {
    width: 6px; height: 6px; border-radius: 50%; background: var(--accent-b);
    box-shadow: 0 0 0 0 rgba(62, 198, 255, 0.6);
    animation: eyebrowPulse 1.8s infinite;
  }
  @keyframes eyebrowPulse {
    0% { box-shadow: 0 0 0 0 rgba(62, 198, 255, 0.55); }
    70% { box-shadow: 0 0 0 7px rgba(62, 198, 255, 0); }
    100% { box-shadow: 0 0 0 0 rgba(62, 198, 255, 0); }
  }

  h1 {
    font-size: clamp(1.7rem, 4vw, 2.35rem);
    font-weight: 800;
    line-height: 1.15;
    margin: 0 0 0.6rem;
    background: linear-gradient(100deg, #ffffff 10%, #c9d3ff 55%, var(--accent-b) 100%);
    -webkit-background-clip: text;
    background-clip: text;
    color: transparent;
    letter-spacing: -0.01em;
  }
  .subtitle { color: var(--muted); margin: 0; font-size: 0.98rem; max-width: 46rem; line-height: 1.55; }

  .card {
    background: var(--card);
    backdrop-filter: blur(18px);
    -webkit-backdrop-filter: blur(18px);
    border-radius: 18px;
    border: 1px solid var(--border);
    box-shadow: 0 20px 50px -25px rgba(0, 0, 0, 0.6), inset 0 1px 0 rgba(255, 255, 255, 0.04);
  }

  .upload-card { padding: 1.75rem; margin: 2rem 0; }

  .dropzone {
    border: 1.5px dashed var(--border-strong);
    border-radius: 14px;
    padding: 1.75rem 1.25rem;
    text-align: center;
    cursor: pointer;
    transition: border-color 0.2s, background 0.2s, transform 0.15s;
    background: rgba(255, 255, 255, 0.015);
  }
  .dropzone:hover { border-color: var(--accent-b); background: rgba(62, 198, 255, 0.04); }
  .dropzone.drag-over { border-color: var(--accent-b); background: rgba(62, 198, 255, 0.08); transform: scale(1.005); }
  .dropzone .dz-icon { font-size: 1.9rem; margin-bottom: 0.5rem; line-height: 1; }
  .dropzone .dz-title { font-weight: 600; font-size: 0.95rem; }
  .dropzone .dz-sub { color: var(--muted); font-size: 0.8rem; margin-top: 0.3rem; }
  .dropzone .dz-file {
    margin-top: 0.9rem;
    display: none;
    align-items: center;
    justify-content: center;
    gap: 0.5rem;
    font-size: 0.85rem;
    background: rgba(79, 140, 255, 0.1);
    border: 1px solid rgba(79, 140, 255, 0.3);
    border-radius: 10px;
    padding: 0.5rem 0.8rem;
    color: var(--text);
  }
  .dropzone .dz-file.show { display: inline-flex; }
  .dropzone .dz-file .fname { font-weight: 600; max-width: 20rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .dropzone .dz-file .fsize { color: var(--muted); font-family: "JetBrains Mono", monospace; font-size: 0.75rem; }

  .res-picker { margin-top: 1.5rem; }
  .res-picker .res-label {
    font-size: 0.78rem; font-weight: 600; color: var(--muted);
    text-transform: uppercase; letter-spacing: 0.05em;
    margin-bottom: 0.6rem;
  }
  .res-options { display: flex; gap: 0.55rem; flex-wrap: wrap; }
  .res-pill {
    position: relative;
    display: inline-flex; align-items: center;
    cursor: pointer;
    user-select: none;
  }
  .res-pill input {
    position: absolute; opacity: 0; width: 100%; height: 100%; margin: 0; cursor: pointer;
  }
  .res-pill span {
    display: inline-flex; align-items: center; gap: 0.3rem;
    padding: 0.42rem 0.9rem;
    border-radius: 999px;
    border: 1px solid var(--border-strong);
    background: rgba(255, 255, 255, 0.02);
    font-size: 0.82rem;
    font-weight: 600;
    color: var(--muted);
    transition: all 0.15s;
  }
  .res-pill input:checked + span {
    background: linear-gradient(120deg, var(--accent-a), var(--accent-b));
    border-color: transparent;
    color: #06101f;
  }
  .res-pill input:focus-visible + span { outline: 2px solid var(--accent-b); outline-offset: 2px; }
  .res-pill:hover span { border-color: var(--accent-b); color: var(--text); }

  .action-row {
    display: flex; align-items: center; gap: 0.9rem; flex-wrap: wrap;
    margin-top: 1.5rem;
  }

  button#startBtn {
    background: linear-gradient(120deg, var(--accent-a), var(--accent-b));
    color: #06101f;
    border: none;
    padding: 0.75rem 1.6rem;
    border-radius: 11px;
    font-size: 0.95rem;
    font-weight: 700;
    cursor: pointer;
    box-shadow: 0 10px 25px -10px rgba(109, 91, 255, 0.6);
    transition: transform 0.15s, box-shadow 0.15s, filter 0.15s;
  }
  button#startBtn:disabled { background: #2a3352; color: var(--muted); cursor: not-allowed; box-shadow: none; }
  button#startBtn:hover:not(:disabled) { transform: translateY(-1px); filter: brightness(1.06); }
  button#startBtn:active:not(:disabled) { transform: translateY(0); }

  .status-line { font-size: 0.88rem; color: var(--muted); min-height: 1.2rem; display: flex; align-items: center; gap: 0.5rem; }
  .status-line.error { color: var(--failed); }
  .status-line .spinner-sm {
    width: 13px; height: 13px; border-radius: 50%;
    border: 2px solid rgba(148, 163, 184, 0.25); border-top-color: var(--running);
    animation: spin 0.8s linear infinite; flex-shrink: 0;
  }

  .job-id {
    font-family: "JetBrains Mono", monospace; color: var(--muted);
    font-size: 0.76rem; margin-top: 0.7rem; word-break: break-all;
  }
  .job-id .val { color: var(--accent-b); }

  /* --- progress bar ------------------------------------------------- */
  .progress-wrap { margin: 1.6rem 0 1.4rem; }
  .progress-head {
    display: flex; justify-content: space-between; align-items: baseline;
    font-size: 0.78rem; color: var(--muted); margin-bottom: 0.5rem;
  }
  .progress-head .pct { font-family: "JetBrains Mono", monospace; font-weight: 600; color: var(--text); }
  .progress-track {
    height: 8px; border-radius: 999px; background: rgba(148, 163, 184, 0.12);
    overflow: hidden; border: 1px solid var(--border);
  }
  .progress-fill {
    height: 100%; width: 0%;
    background: linear-gradient(90deg, var(--accent-a), var(--accent-b), var(--succeeded));
    border-radius: 999px;
    transition: width 0.5s cubic-bezier(0.4, 0, 0.2, 1);
    box-shadow: 0 0 12px var(--running-glow);
  }

  /* --- pipeline flow -------------------------------------------------- */
  .flow { display: flex; flex-direction: column; padding: 1.75rem; }
  .node-row { display: flex; gap: 0.6rem; }
  .node-row.pair { gap: 0.6rem; }
  .node-row.pair > .node { flex: 1; }

  .node {
    background: rgba(255, 255, 255, 0.02);
    border: 1px solid var(--border);
    border-radius: 13px;
    padding: 0.85rem 1rem;
    display: flex;
    align-items: center;
    gap: 0.8rem;
    flex: 1;
    transition: border-color 0.3s, background 0.3s, box-shadow 0.3s, transform 0.2s;
  }
  .node .icon-wrap { flex-shrink: 0; display: flex; align-items: center; justify-content: center; }
  .node .dot {
    width: 30px; height: 30px; border-radius: 50%;
    background: rgba(148, 163, 184, 0.14);
    border: 2px solid var(--pending);
    display: flex; align-items: center; justify-content: center;
    font-size: 14px; font-weight: 800;
    color: transparent;
    transition: all 0.3s;
  }
  .node .text { min-width: 0; }
  .node .label { font-weight: 600; font-size: 0.9rem; }
  .node .sub { font-size: 0.74rem; color: var(--muted); margin-top: 0.12rem; }

  .node.running {
    border-color: rgba(79, 140, 255, 0.45);
    background: rgba(79, 140, 255, 0.06);
    box-shadow: 0 0 0 1px rgba(79, 140, 255, 0.12), 0 8px 24px -12px var(--running-glow);
  }
  .node.running .dot {
    background: transparent;
    border: 2.5px solid rgba(79, 140, 255, 0.25);
    border-top-color: var(--running);
    animation: spin 0.85s linear infinite;
  }
  .node.running .label { color: var(--running); }

  .node.succeeded {
    border-color: rgba(47, 214, 127, 0.4);
    background: rgba(47, 214, 127, 0.05);
  }
  .node.succeeded .dot {
    background: linear-gradient(135deg, var(--succeeded), #1fae66);
    border-color: transparent;
    color: #06210f;
  }
  .node.succeeded .dot::after { content: "✓"; }

  .node.failed {
    border-color: rgba(255, 84, 112, 0.45);
    background: rgba(255, 84, 112, 0.06);
    box-shadow: 0 0 0 1px rgba(255, 84, 112, 0.12), 0 8px 24px -12px var(--failed-glow);
  }
  .node.failed .dot {
    background: linear-gradient(135deg, var(--failed), #c22449);
    border-color: transparent;
    color: #2a020c;
  }
  .node.failed .dot::after { content: "✕"; }
  .node.failed .label { color: var(--failed); }

  @keyframes spin { to { transform: rotate(360deg); } }

  .connector {
    width: 2px; height: 20px; margin-left: 2.35rem;
    background: var(--border-strong);
    transition: background 0.4s;
  }
  .connector.done { background: linear-gradient(180deg, var(--succeeded), rgba(47, 214, 127, 0.3)); }

  /* --- result / downloads ---------------------------------------------- */
  .result { padding: 1.75rem; margin-top: 1.5rem; display: none; opacity: 0; transform: translateY(6px); transition: opacity 0.4s, transform 0.4s; }
  .result.show { display: block; opacity: 1; transform: translateY(0); }
  .result h3 { margin: 0 0 1rem; font-size: 1.1rem; font-weight: 700; }

  .downloads { margin-bottom: 1.1rem; display: none; }
  .downloads.show { display: block; }
  .downloads .thumb-wrap {
    display: inline-block; border-radius: 12px; overflow: hidden;
    border: 1px solid var(--border-strong); margin-bottom: 1rem;
    box-shadow: 0 12px 30px -14px rgba(0, 0, 0, 0.7);
  }
  .downloads .thumb { max-width: 260px; display: block; }
  .downloads .dl-row { display: flex; gap: 0.6rem; flex-wrap: wrap; }
  .downloads .dl-btn {
    display: inline-flex; align-items: center; gap: 0.4rem;
    background: linear-gradient(120deg, var(--succeeded), #1fae66);
    color: #06210f;
    font-weight: 700;
    text-decoration: none;
    padding: 0.5rem 1rem;
    border-radius: 9px;
    font-size: 0.83rem;
    transition: transform 0.15s, filter 0.15s;
  }
  .downloads .dl-btn:hover { filter: brightness(1.07); transform: translateY(-1px); }
  .downloads .dl-status { font-size: 0.8rem; color: var(--muted); }

  details.raw-output { margin-top: 0.4rem; }
  details.raw-output summary {
    cursor: pointer; font-size: 0.8rem; color: var(--muted);
    user-select: none;
  }
  details.raw-output summary:hover { color: var(--text); }
  .result pre {
    background: #060a17;
    border: 1px solid var(--border);
    padding: 0.9rem;
    border-radius: 10px;
    overflow-x: auto;
    font-size: 0.76rem;
    font-family: "JetBrains Mono", monospace;
    margin: 0.6rem 0 0;
    color: #c7d0ea;
  }

  .reset-link {
    display: inline-flex; align-items: center; gap: 0.3rem;
    margin-top: 1.1rem;
    color: var(--accent-b);
    cursor: pointer;
    font-size: 0.85rem;
    font-weight: 600;
    text-decoration: none;
    border-bottom: 1px solid transparent;
    transition: border-color 0.15s;
  }
  .reset-link:hover { border-bottom-color: var(--accent-b); }

  footer.foot { text-align: center; margin-top: 2.5rem; color: var(--muted); font-size: 0.76rem; }
  footer.foot a { color: var(--accent-b); text-decoration: none; }

  @media (max-width: 520px) {
    .node-row.pair { flex-direction: column; }
    .downloads .thumb { max-width: 100%; }
  }
</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    <div class="eyebrow"><span class="pulse-dot"></span> Live Step Functions demo</div>
    <h1>AWS Step Functions Video Pipeline</h1>
    <p class="subtitle">Upload a video and watch it move through validation, parallel thumbnail/metadata extraction, multi-resolution transcoding on ECS Fargate, and completion — in real time, straight from the actual Step Functions execution history.</p>
  </div>

  <div class="card upload-card">
    <div class="dropzone" id="dropzone">
      <input type="file" id="fileInput" accept="video/*" hidden />
      <div class="dz-icon">🎬</div>
      <div class="dz-title">Drop a video here, or click to browse</div>
      <div class="dz-sub">MP4, MOV, MKV, or AVI</div>
      <div class="dz-file" id="dzFile">
        <span class="fname" id="dzFileName"></span>
        <span class="fsize" id="dzFileSize"></span>
      </div>
    </div>

    <div class="res-picker">
      <div class="res-label">Resolutions to transcode</div>
      <div class="res-options" id="resOptions">
        <label class="res-pill"><input type="checkbox" value="1440p" /><span>1440p</span></label>
        <label class="res-pill"><input type="checkbox" value="1080p" checked /><span>1080p</span></label>
        <label class="res-pill"><input type="checkbox" value="720p" checked /><span>720p</span></label>
        <label class="res-pill"><input type="checkbox" value="480p" checked /><span>480p</span></label>
        <label class="res-pill"><input type="checkbox" value="360p" /><span>360p</span></label>
        <label class="res-pill"><input type="checkbox" value="240p" /><span>240p</span></label>
      </div>
    </div>

    <div class="action-row">
      <button id="startBtn">Start Processing</button>
      <div class="status-line" id="statusLine"></div>
    </div>
    <div class="job-id" id="jobIdLine"></div>
  </div>

  <div class="progress-wrap" id="progressWrap" style="display:none;">
    <div class="progress-head">
      <span id="progressLabel">Starting…</span>
      <span class="pct" id="progressPct">0%</span>
    </div>
    <div class="progress-track"><div class="progress-fill" id="progressFill"></div></div>
  </div>

  <div class="card flow" id="flow" style="display:none;">
    <div class="node-row"><div class="node" id="node-create_job"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Initialize Job</div><div class="sub">Create DynamoDB record</div></div></div></div>
    <div class="connector" id="connector-1"></div>
    <div class="node-row"><div class="node" id="node-validate"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Validate Video</div><div class="sub">Format &amp; size checks</div></div></div></div>
    <div class="connector" id="connector-2"></div>
    <div class="node-row pair">
      <div class="node" id="node-generate_thumbnail"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Generate Thumbnail</div><div class="sub">Parallel branch</div></div></div>
      <div class="node" id="node-extract_metadata"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Extract Metadata</div><div class="sub">Parallel branch</div></div></div>
    </div>
    <div class="connector" id="connector-3"></div>
    <div class="node-row"><div class="node" id="node-record_media"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Record Media Details</div><div class="sub">Write metadata to DynamoDB</div></div></div></div>
    <div class="connector" id="connector-4"></div>
    <div class="node-row"><div class="node" id="node-transcode"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Transcode Video</div><div class="sub" id="transcode-sub">ECS Fargate, all requested resolutions</div></div></div></div>
    <div class="connector" id="connector-5"></div>
    <div class="node-row"><div class="node" id="node-record_complete"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Record Job Complete</div><div class="sub">Final DynamoDB update</div></div></div></div>
    <div class="connector" id="connector-6"></div>
    <div class="node-row"><div class="node" id="node-notify"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label">Send Notification</div><div class="sub">SNS</div></div></div></div>
    <div class="connector" id="connector-7"></div>
    <div class="node-row"><div class="node" id="node-done"><div class="icon-wrap"><div class="dot"></div></div><div class="text"><div class="label" id="done-label">Job Result</div><div class="sub" id="done-sub">Waiting...</div></div></div></div>
  </div>

  <div class="card result" id="result">
    <h3 id="result-title"></h3>
    <div class="downloads" id="downloads">
      <div class="thumb-wrap" id="thumbWrap" style="display:none;"><img class="thumb" id="thumbImg" /></div>
      <div class="dl-row" id="dlRow"></div>
      <div class="dl-status" id="dlStatus"></div>
    </div>
    <details class="raw-output">
      <summary>Raw execution output</summary>
      <pre id="result-body"></pre>
    </details>
    <a class="reset-link" id="resetLink">↻ Upload another video</a>
  </div>

  <footer class="foot">Step Functions → Lambda → ECS Fargate, orchestrating a real AWS pipeline in real time.</footer>
</div>

<script>
const API_BASE = "${api_base_url}";

const dropzone = document.getElementById("dropzone");
const fileInput = document.getElementById("fileInput");
const dzFile = document.getElementById("dzFile");
const dzFileName = document.getElementById("dzFileName");
const dzFileSize = document.getElementById("dzFileSize");
const startBtn = document.getElementById("startBtn");
const statusLine = document.getElementById("statusLine");
const jobIdLine = document.getElementById("jobIdLine");
const progressWrap = document.getElementById("progressWrap");
const progressFill = document.getElementById("progressFill");
const progressPct = document.getElementById("progressPct");
const progressLabel = document.getElementById("progressLabel");
const flow = document.getElementById("flow");
const result = document.getElementById("result");
const resultTitle = document.getElementById("result-title");
const resultBody = document.getElementById("result-body");
const resetLink = document.getElementById("resetLink");
const transcodeSub = document.getElementById("transcode-sub");
const doneLabel = document.getElementById("done-label");
const doneSub = document.getElementById("done-sub");
const resOptions = document.getElementById("resOptions");
const downloads = document.getElementById("downloads");
const thumbWrap = document.getElementById("thumbWrap");
const thumbImg = document.getElementById("thumbImg");
const dlRow = document.getElementById("dlRow");
const dlStatus = document.getElementById("dlStatus");

const NODE_ORDER = [
  "create_job", "validate", "generate_thumbnail", "extract_metadata",
  "record_media", "transcode", "record_complete", "notify", "done",
];

let pollTimer = null;
let notFoundStreak = 0;
const MAX_NOT_FOUND_ATTEMPTS = 15; // ~30s grace period for EventBridge + trigger Lambda

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB", "GB"];
  let i = 0;
  let val = bytes;
  while (val >= 1024 && i < units.length - 1) {
    val /= 1024;
    i++;
  }
  return val.toFixed(val >= 10 || i === 0 ? 0 : 1) + " " + units[i];
}

function showFile(file) {
  dzFileName.textContent = file.name;
  dzFileSize.textContent = formatBytes(file.size);
  dzFile.classList.add("show");
}

function setStatus(msg, isError, spinning) {
  statusLine.innerHTML = "";
  statusLine.className = "status-line" + (isError ? " error" : "");
  if (spinning) {
    const s = document.createElement("span");
    s.className = "spinner-sm";
    statusLine.appendChild(s);
  }
  const t = document.createElement("span");
  t.textContent = msg;
  statusLine.appendChild(t);
}

function setNode(nodeId, status) {
  const el = document.getElementById("node-" + nodeId);
  if (!el) return;
  el.className = "node " + status;
}

function updateProgress(nodes) {
  const total = NODE_ORDER.length;
  let done = 0;
  let runningLabel = null;
  NODE_ORDER.forEach((id) => {
    const st = nodes[id] && nodes[id].status;
    if (st === "succeeded") done++;
    if (st === "running" && !runningLabel) {
      const labelEl = document.querySelector("#node-" + id + " .label");
      runningLabel = labelEl ? labelEl.textContent : id;
    }
  });
  const pct = Math.round((done / total) * 100);
  progressFill.style.width = pct + "%";
  progressPct.textContent = pct + "%";
  progressLabel.textContent = runningLabel ? "Running: " + runningLabel : (pct >= 100 ? "Complete" : "Starting…");

  // Color the connector below any node that has succeeded, so the
  // timeline visually "fills in" as the execution progresses.
  const connectorAfter = {
    create_job: 1, validate: 2, extract_metadata: 3, generate_thumbnail: 3,
    record_media: 4, transcode: 5, record_complete: 6, notify: 7,
  };
  Object.entries(connectorAfter).forEach(([nodeId, idx]) => {
    const st = nodes[nodeId] && nodes[nodeId].status;
    const c = document.getElementById("connector-" + idx);
    if (c && st === "succeeded") c.classList.add("done");
  });
}

function applyNodes(nodes) {
  for (const [nodeId, info] of Object.entries(nodes)) {
    setNode(nodeId, info.status);
    if (nodeId === "transcode" && info.progress) {
      transcodeSub.textContent = "ECS Fargate — " + info.progress + " resolutions complete";
    }
  }
  updateProgress(nodes);
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function renderDownloads(job_id, dl) {
  dlRow.innerHTML = "";
  thumbWrap.style.display = "none";

  if (dl.thumbnail_url) {
    thumbImg.src = dl.thumbnail_url;
    thumbWrap.style.display = "inline-block";
  }

  const resolutions = Object.keys(dl.videos || {});
  if (resolutions.length === 0) {
    dlStatus.textContent = "No transcoded resolutions found for this job.";
  } else {
    dlStatus.textContent = "";
    resolutions.forEach((res) => {
      const a = document.createElement("a");
      a.className = "dl-btn";
      a.href = dl.videos[res];
      a.textContent = "⬇ " + res;
      a.setAttribute("download", job_id + "-" + res + ".mp4");
      dlRow.appendChild(a);
    });
  }
  downloads.classList.add("show");
}

async function loadDownloads(job_id) {
  dlStatus.textContent = "Preparing download links...";
  downloads.classList.add("show");
  try {
    const resp = await fetch(API_BASE + "/download/" + encodeURIComponent(job_id));
    if (!resp.ok) {
      dlStatus.textContent = "Downloads aren't ready yet (" + resp.status + ").";
      return;
    }
    const dl = await resp.json();
    renderDownloads(job_id, dl);
  } catch (err) {
    dlStatus.textContent = "Error loading downloads: " + err.message;
  }
}

function showTerminal(body) {
  stopPolling();
  if (body.execution_status === "SUCCEEDED") {
    doneLabel.textContent = "Job Succeeded";
    doneSub.textContent = "Pipeline completed successfully";
    setNode("done", "succeeded");
    resultTitle.textContent = "✅ Execution succeeded";
    progressLabel.textContent = "Complete";
    progressFill.style.width = "100%";
    progressPct.textContent = "100%";
    resultBody.textContent = JSON.stringify(body.output || {}, null, 2);
    loadDownloads(body.job_id);
  } else {
    doneLabel.textContent = "Job Failed";
    doneSub.textContent = body.error || body.execution_status;
    setNode("done", "failed");
    resultTitle.textContent = "❌ Execution failed";
    resultBody.textContent = (body.error || "") + "\\n\\n" + (body.cause || "");
  }
  result.classList.add("show");
  setStatus("");
}

async function poll(jobId) {
  try {
    const resp = await fetch(API_BASE + "/status/" + encodeURIComponent(jobId));

    if (resp.status === 404) {
      notFoundStreak++;
      if (notFoundStreak > MAX_NOT_FOUND_ATTEMPTS) {
        stopPolling();
        setStatus("Execution never started. Check the EventBridge rule / trigger Lambda logs.", true);
      } else {
        setStatus("Waiting for the pipeline to start (EventBridge + trigger Lambda)...", false, true);
      }
      return;
    }
    notFoundStreak = 0;

    const body = await resp.json();
    applyNodes(body.nodes || {});

    if (body.execution_status === "RUNNING") {
      setStatus("Running...", false, true);
    } else {
      showTerminal(body);
    }
  } catch (err) {
    setStatus("Error polling status: " + err.message, true);
  }
}

function resetUI() {
  stopPolling();
  fileInput.value = "";
  dzFile.classList.remove("show");
  startBtn.disabled = false;
  statusLine.innerHTML = "";
  statusLine.className = "status-line";
  jobIdLine.innerHTML = "";
  flow.style.display = "none";
  progressWrap.style.display = "none";
  progressFill.style.width = "0%";
  progressPct.textContent = "0%";
  result.classList.remove("show");
  downloads.classList.remove("show");
  dlRow.innerHTML = "";
  dlStatus.textContent = "";
  thumbWrap.style.display = "none";
  thumbImg.src = "";
  document.querySelectorAll(".node").forEach((el) => (el.className = "node"));
  document.querySelectorAll(".connector").forEach((el) => el.classList.remove("done"));
  transcodeSub.textContent = "ECS Fargate, all requested resolutions";
  doneLabel.textContent = "Job Result";
  doneSub.textContent = "Waiting...";
}

resetLink.addEventListener("click", resetUI);

function selectedResolutions() {
  return Array.from(resOptions.querySelectorAll("input[type=checkbox]:checked")).map((el) => el.value);
}

// --- dropzone: click-to-browse + drag & drop --------------------------------

dropzone.addEventListener("click", () => fileInput.click());

fileInput.addEventListener("change", () => {
  if (fileInput.files[0]) showFile(fileInput.files[0]);
});

["dragenter", "dragover"].forEach((evt) => {
  dropzone.addEventListener(evt, (e) => {
    e.preventDefault();
    dropzone.classList.add("drag-over");
  });
});

["dragleave", "dragend"].forEach((evt) => {
  dropzone.addEventListener(evt, () => dropzone.classList.remove("drag-over"));
});

dropzone.addEventListener("drop", (e) => {
  e.preventDefault();
  dropzone.classList.remove("drag-over");
  const dropped = e.dataTransfer.files;
  if (dropped && dropped[0]) {
    fileInput.files = dropped;
    showFile(dropped[0]);
  }
});

// --- upload + track ----------------------------------------------------------

startBtn.addEventListener("click", async () => {
  const file = fileInput.files[0];
  if (!file) {
    setStatus("Choose a video file first.", true);
    return;
  }

  const resolutions = selectedResolutions();
  if (resolutions.length === 0) {
    setStatus("Pick at least one resolution to transcode.", true);
    return;
  }

  startBtn.disabled = true;
  result.classList.remove("show");
  setStatus("Requesting upload URL...", false, true);

  try {
    const presignResp = await fetch(API_BASE + "/presign", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolutions }),
    });
    if (!presignResp.ok) throw new Error("presign request failed (" + presignResp.status + ")");
    const { job_id, upload_url, upload_headers, resolutions: acceptedResolutions } = await presignResp.json();

    jobIdLine.innerHTML = "job_id: <span class='val'>" + job_id + "</span> &nbsp;|&nbsp; resolutions: <span class='val'>" + acceptedResolutions.join(", ") + "</span>";
    setStatus("Uploading " + file.name + "...", false, true);

    // upload_headers comes straight from the presign response and must be
    // sent verbatim -- it's exactly what was cryptographically signed into
    // upload_url (including the resolutions choice as object metadata), so
    // hardcoding headers here instead would fail the PUT with a signature
    // mismatch the moment they drift apart.
    const putResp = await fetch(upload_url, {
      method: "PUT",
      headers: upload_headers,
      body: file,
    });
    if (!putResp.ok) throw new Error("upload failed (" + putResp.status + ")");

    setStatus("Uploaded. Waiting for the pipeline to start...", false, true);
    flow.style.display = "flex";
    progressWrap.style.display = "block";
    document.querySelectorAll(".node").forEach((el) => (el.className = "node"));
    document.querySelectorAll(".connector").forEach((el) => el.classList.remove("done"));
    notFoundStreak = 0;

    poll(job_id);
    pollTimer = setInterval(() => poll(job_id), 2000);
  } catch (err) {
    setStatus("Error: " + err.message, true);
    startBtn.disabled = false;
  }
});
</script>
</body>
</html>
