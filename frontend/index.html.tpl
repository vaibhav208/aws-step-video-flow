<!DOCTYPE html>
<!--
  Phase 6 frontend — a single self-contained HTML file (no build step, no
  external dependencies) that uploads a video straight to S3 via a
  pre-signed URL, then polls the web_api Lambda's /status/{job_id} route to
  animate the Step Functions execution's state transitions live.

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
<style>
  :root {
    --pending: #cbd5e1;
    --running: #3b82f6;
    --succeeded: #22c55e;
    --failed: #ef4444;
    --bg: #0f172a;
    --card: #1e293b;
    --text: #e2e8f0;
    --muted: #94a3b8;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    min-height: 100vh;
    padding: 2rem 1rem 4rem;
  }
  .wrap { max-width: 720px; margin: 0 auto; }
  h1 { font-size: 1.4rem; margin-bottom: 0.25rem; }
  .subtitle { color: var(--muted); margin-top: 0; margin-bottom: 2rem; font-size: 0.9rem; }

  .upload-card {
    background: var(--card);
    border-radius: 12px;
    padding: 1.5rem;
    margin-bottom: 2rem;
    border: 1px solid #334155;
  }
  .upload-row { display: flex; gap: 0.75rem; flex-wrap: wrap; align-items: center; }
  input[type=file] { color: var(--text); flex: 1; min-width: 200px; }
  button {
    background: var(--running);
    color: white;
    border: none;
    padding: 0.6rem 1.4rem;
    border-radius: 8px;
    font-size: 0.95rem;
    cursor: pointer;
    font-weight: 600;
  }
  button:disabled { background: #475569; cursor: not-allowed; }
  button:hover:not(:disabled) { filter: brightness(1.1); }

  .status-line { margin-top: 1rem; font-size: 0.9rem; color: var(--muted); min-height: 1.2rem; }
  .status-line.error { color: var(--failed); }

  .job-id { font-family: monospace; color: var(--muted); font-size: 0.8rem; margin-top: 0.5rem; }

  .flow { display: flex; flex-direction: column; gap: 0.5rem; }
  .node-row { display: flex; gap: 0.5rem; }
  .node-row.pair > .node { flex: 1; }

  .node {
    background: var(--card);
    border: 2px solid var(--pending);
    border-radius: 10px;
    padding: 0.9rem 1.1rem;
    display: flex;
    justify-content: space-between;
    align-items: center;
    transition: border-color 0.3s, background 0.3s;
  }
  .node .label { font-weight: 600; font-size: 0.92rem; }
  .node .sub { font-size: 0.75rem; color: var(--muted); margin-top: 0.15rem; }
  .node .dot {
    width: 12px; height: 12px; border-radius: 50%;
    background: var(--pending); flex-shrink: 0;
  }

  .node.running { border-color: var(--running); }
  .node.running .dot { background: var(--running); animation: pulse 1.1s infinite ease-in-out; }
  .node.succeeded { border-color: var(--succeeded); }
  .node.succeeded .dot { background: var(--succeeded); }
  .node.failed { border-color: var(--failed); }
  .node.failed .dot { background: var(--failed); }

  @keyframes pulse {
    0%, 100% { transform: scale(1); opacity: 1; }
    50% { transform: scale(1.3); opacity: 0.6; }
  }

  .connector { width: 2px; height: 14px; background: #334155; margin-left: 1.6rem; }

  .result {
    margin-top: 1.5rem;
    background: var(--card);
    border-radius: 10px;
    padding: 1rem 1.2rem;
    border: 1px solid #334155;
    display: none;
  }
  .result.show { display: block; }
  .result h3 { margin: 0 0 0.5rem; font-size: 0.95rem; }
  .result pre {
    background: #0f172a;
    padding: 0.75rem;
    border-radius: 6px;
    overflow-x: auto;
    font-size: 0.78rem;
    margin: 0;
  }
  .reset-link {
    display: inline-block;
    margin-top: 0.9rem;
    color: var(--running);
    cursor: pointer;
    font-size: 0.85rem;
    text-decoration: underline;
  }

  .res-picker { margin-top: 1rem; }
  .res-picker .res-label { font-size: 0.8rem; color: var(--muted); margin-bottom: 0.4rem; }
  .res-options { display: flex; gap: 0.9rem; flex-wrap: wrap; }
  .res-options label {
    display: flex; align-items: center; gap: 0.35rem;
    font-size: 0.85rem; cursor: pointer;
  }
  .res-options input { accent-color: var(--running); cursor: pointer; }

  .downloads {
    margin-top: 1rem;
    display: none;
  }
  .downloads.show { display: block; }
  .downloads .thumb {
    max-width: 220px;
    border-radius: 8px;
    border: 1px solid #334155;
    display: block;
    margin-bottom: 0.9rem;
  }
  .downloads .dl-row { display: flex; gap: 0.6rem; flex-wrap: wrap; }
  .downloads .dl-btn {
    background: var(--succeeded);
    color: #052e16;
    font-weight: 700;
    text-decoration: none;
    padding: 0.45rem 0.9rem;
    border-radius: 7px;
    font-size: 0.85rem;
  }
  .downloads .dl-btn:hover { filter: brightness(1.08); }
  .downloads .dl-status { font-size: 0.8rem; color: var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <h1>AWS Step Functions Video Pipeline</h1>
  <p class="subtitle">Upload a video, watch it move through validation, metadata/thumbnail extraction, transcoding, and completion in real time.</p>

  <div class="upload-card">
    <div class="upload-row">
      <input type="file" id="fileInput" accept="video/*" />
      <button id="startBtn">Start Processing</button>
    </div>
    <div class="res-picker">
      <div class="res-label">Resolutions to transcode (pick at least one):</div>
      <div class="res-options" id="resOptions">
        <label><input type="checkbox" value="1440p" /> 1440p</label>
        <label><input type="checkbox" value="1080p" checked /> 1080p</label>
        <label><input type="checkbox" value="720p" checked /> 720p</label>
        <label><input type="checkbox" value="480p" checked /> 480p</label>
        <label><input type="checkbox" value="360p" /> 360p</label>
        <label><input type="checkbox" value="240p" /> 240p</label>
      </div>
    </div>
    <div class="status-line" id="statusLine"></div>
    <div class="job-id" id="jobIdLine"></div>
  </div>

  <div class="flow" id="flow" style="display:none;">
    <div class="node-row"><div class="node" id="node-create_job"><div><div class="label">Initialize Job</div><div class="sub">Create DynamoDB record</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-validate"><div><div class="label">Validate Video</div><div class="sub">Format &amp; size checks</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row pair">
      <div class="node" id="node-generate_thumbnail"><div><div class="label">Generate Thumbnail</div><div class="sub">Parallel branch</div></div><div class="dot"></div></div>
      <div class="node" id="node-extract_metadata"><div><div class="label">Extract Metadata</div><div class="sub">Parallel branch</div></div><div class="dot"></div></div>
    </div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-record_media"><div><div class="label">Record Media Details</div><div class="sub">Write metadata to DynamoDB</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-transcode"><div><div class="label">Transcode Video</div><div class="sub" id="transcode-sub">ECS Fargate, all requested resolutions</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-record_complete"><div><div class="label">Record Job Complete</div><div class="sub">Final DynamoDB update</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-notify"><div><div class="label">Send Notification</div><div class="sub">SNS</div></div><div class="dot"></div></div></div>
    <div class="connector"></div>
    <div class="node-row"><div class="node" id="node-done"><div><div class="label" id="done-label">Job Result</div><div class="sub" id="done-sub">Waiting...</div></div><div class="dot"></div></div></div>
  </div>

  <div class="result" id="result">
    <h3 id="result-title"></h3>
    <div class="downloads" id="downloads">
      <img class="thumb" id="thumbImg" style="display:none;" />
      <div class="dl-row" id="dlRow"></div>
      <div class="dl-status" id="dlStatus"></div>
    </div>
    <pre id="result-body"></pre>
    <a class="reset-link" id="resetLink">Upload another video &rarr;</a>
  </div>
</div>

<script>
const API_BASE = "${api_base_url}";

const fileInput = document.getElementById("fileInput");
const startBtn = document.getElementById("startBtn");
const statusLine = document.getElementById("statusLine");
const jobIdLine = document.getElementById("jobIdLine");
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
const thumbImg = document.getElementById("thumbImg");
const dlRow = document.getElementById("dlRow");
const dlStatus = document.getElementById("dlStatus");

let pollTimer = null;
let notFoundStreak = 0;
const MAX_NOT_FOUND_ATTEMPTS = 15; // ~30s grace period for EventBridge + trigger Lambda

function setStatus(msg, isError) {
  statusLine.textContent = msg;
  statusLine.className = "status-line" + (isError ? " error" : "");
}

function setNode(nodeId, status) {
  const el = document.getElementById("node-" + nodeId);
  if (!el) return;
  el.className = "node " + status;
}

function applyNodes(nodes) {
  for (const [nodeId, info] of Object.entries(nodes)) {
    setNode(nodeId, info.status);
    if (nodeId === "transcode" && info.progress) {
      transcodeSub.textContent = "ECS Fargate — " + info.progress + " resolutions complete";
    }
  }
}

function stopPolling() {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
}

function renderDownloads(job_id, dl) {
  dlRow.innerHTML = "";
  thumbImg.style.display = "none";

  if (dl.thumbnail_url) {
    thumbImg.src = dl.thumbnail_url;
    thumbImg.style.display = "block";
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
      a.textContent = "Download " + res;
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
        setStatus("Waiting for the pipeline to start (EventBridge + trigger Lambda)...");
      }
      return;
    }
    notFoundStreak = 0;

    const body = await resp.json();
    applyNodes(body.nodes || {});

    if (body.execution_status === "RUNNING") {
      setStatus("Running...");
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
  startBtn.disabled = false;
  statusLine.textContent = "";
  jobIdLine.textContent = "";
  flow.style.display = "none";
  result.classList.remove("show");
  downloads.classList.remove("show");
  dlRow.innerHTML = "";
  dlStatus.textContent = "";
  thumbImg.style.display = "none";
  thumbImg.src = "";
  document.querySelectorAll(".node").forEach((el) => (el.className = "node"));
  transcodeSub.textContent = "ECS Fargate, all requested resolutions";
  doneLabel.textContent = "Job Result";
  doneSub.textContent = "Waiting...";
}

resetLink.addEventListener("click", resetUI);

function selectedResolutions() {
  return Array.from(resOptions.querySelectorAll("input[type=checkbox]:checked")).map((el) => el.value);
}

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
  setStatus("Requesting upload URL...");

  try {
    const presignResp = await fetch(API_BASE + "/presign", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ resolutions }),
    });
    if (!presignResp.ok) throw new Error("presign request failed (" + presignResp.status + ")");
    const { job_id, upload_url, upload_headers, resolutions: acceptedResolutions } = await presignResp.json();

    jobIdLine.textContent = "job_id: " + job_id + "  |  resolutions: " + acceptedResolutions.join(", ");
    setStatus("Uploading " + file.name + "...");

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

    setStatus("Uploaded. Waiting for the pipeline to start...");
    flow.style.display = "flex";
    document.querySelectorAll(".node").forEach((el) => (el.className = "node"));
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
