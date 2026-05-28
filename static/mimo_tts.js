const state = {
  configured: false,
  voiceUrl: null,
  resultUrl: null,
  generating: false,
};

const refs = {
  toolSelect: document.querySelector("#toolSelect"),
  keyBadge: document.querySelector("#keyBadge"),
  modelBadge: document.querySelector("#modelBadge"),
  apiKeyPanel: document.querySelector("#apiKeyPanel"),
  apiKeyForm: document.querySelector("#apiKeyForm"),
  apiKeyInput: document.querySelector("#apiKeyInput"),
  saveKeyButton: document.querySelector("#saveKeyButton"),
  form: document.querySelector("#ttsForm"),
  voiceInput: document.querySelector("#voiceInput"),
  voicePreviewWrap: document.querySelector("#voicePreviewWrap"),
  voicePreview: document.querySelector("#voicePreview"),
  voiceFileName: document.querySelector("#voiceFileName"),
  textInput: document.querySelector("#textInput"),
  stylePromptInput: document.querySelector("#stylePromptInput"),
  charCount: document.querySelector("#charCount"),
  resetButton: document.querySelector("#resetButton"),
  generateButton: document.querySelector("#generateButton"),
  statusText: document.querySelector("#statusText"),
  resultEmpty: document.querySelector("#resultEmpty"),
  resultReady: document.querySelector("#resultReady"),
  resultAudio: document.querySelector("#resultAudio"),
  resultMeta: document.querySelector("#resultMeta"),
  downloadLink: document.querySelector("#downloadLink"),
};

function setBadge(element, text, kind = "muted") {
  element.textContent = text;
  element.className = `badge ${kind}`;
}

function setStatus(message, isError = false) {
  refs.statusText.textContent = message;
  refs.statusText.classList.toggle("error", isError);
}

function syncGenerateButton() {
  refs.generateButton.disabled = state.generating || !state.configured;
}

function updateCharCount() {
  const limit = Number(refs.textInput.maxLength || 1000);
  refs.charCount.textContent = `${refs.textInput.value.length} / ${limit}`;
}

async function readErrorMessage(response) {
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    const payload = await response.json();
    return payload.detail || JSON.stringify(payload);
  }
  const text = await response.text();
  return text || `HTTP ${response.status}`;
}

async function refreshStatus() {
  try {
    const response = await fetch("/api/mimo/status", { cache: "no-store" });
    if (!response.ok) {
      throw new Error(await readErrorMessage(response));
    }
    const payload = await response.json();
    state.configured = Boolean(payload.configured);
    refs.apiKeyPanel.hidden = state.configured;
    setBadge(
      refs.keyBadge,
      state.configured ? "API Key: 已配置" : "API Key: 未配置",
      state.configured ? "ok" : "warning",
    );
    setBadge(refs.modelBadge, `模型: ${payload.model || "mimo-v2.5-tts-voiceclone"}`, "muted");
    setStatus(state.configured ? "MiMo 已就绪。" : "请先填写 MiMo API Key。", !state.configured);
    syncGenerateButton();
  } catch (error) {
    state.configured = false;
    refs.apiKeyPanel.hidden = false;
    setBadge(refs.keyBadge, "API Key: 状态未知", "error");
    setBadge(refs.modelBadge, "模型: unknown", "muted");
    setStatus(error.message || "无法读取 MiMo 状态。", true);
    syncGenerateButton();
  }
}

async function saveApiKey(event) {
  event.preventDefault();
  const apiKey = refs.apiKeyInput.value.trim();
  if (!apiKey) {
    setStatus("MiMo API Key 不能为空。", true);
    return;
  }

  refs.saveKeyButton.disabled = true;
  setStatus("正在保存 MiMo API Key。");
  try {
    const response = await fetch("/api/mimo/key", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: apiKey }),
    });
    if (!response.ok) {
      throw new Error(await readErrorMessage(response));
    }
    refs.apiKeyInput.value = "";
    await refreshStatus();
    setStatus("MiMo API Key 已保存。");
  } catch (error) {
    setStatus(error.message || "保存 MiMo API Key 失败。", true);
  } finally {
    refs.saveKeyButton.disabled = false;
  }
}

function updateVoicePreview() {
  const file = refs.voiceInput.files && refs.voiceInput.files[0];
  if (state.voiceUrl) {
    URL.revokeObjectURL(state.voiceUrl);
    state.voiceUrl = null;
  }
  if (!file) {
    refs.voicePreviewWrap.hidden = true;
    refs.voicePreview.removeAttribute("src");
    refs.voiceFileName.textContent = "";
    return;
  }
  state.voiceUrl = URL.createObjectURL(file);
  refs.voiceFileName.textContent = file.name;
  refs.voicePreview.src = state.voiceUrl;
  refs.voicePreviewWrap.hidden = false;
}

function clearResult() {
  if (state.resultUrl) {
    URL.revokeObjectURL(state.resultUrl);
    state.resultUrl = null;
  }
  refs.resultAudio.removeAttribute("src");
  refs.resultAudio.load();
  refs.resultMeta.textContent = "";
  refs.downloadLink.href = "#";
  refs.downloadLink.classList.add("disabled");
  refs.resultReady.hidden = true;
  refs.resultEmpty.hidden = false;
}

async function submitTts(event) {
  event.preventDefault();
  if (!state.configured) {
    setStatus("请先填写 MiMo API Key。", true);
    return;
  }
  if (!refs.voiceInput.files.length || !refs.textInput.value.trim()) {
    setStatus("请先选择参考音频并输入文本。", true);
    return;
  }

  const formData = new FormData(refs.form);
  clearResult();
  state.generating = true;
  syncGenerateButton();
  refs.resetButton.disabled = true;
  refs.toolSelect.disabled = true;
  setStatus("正在调用 MiMo 音色克隆。");

  try {
    const response = await fetch("/synthesize", {
      method: "POST",
      body: formData,
    });
    if (!response.ok) {
      throw new Error(await readErrorMessage(response));
    }
    const blob = await response.blob();
    state.resultUrl = URL.createObjectURL(blob);
    refs.resultAudio.src = state.resultUrl;
    refs.downloadLink.href = state.resultUrl;
    refs.downloadLink.download = `mimo-${Date.now()}.wav`;
    refs.downloadLink.classList.remove("disabled");
    refs.resultMeta.textContent = `${Math.round(blob.size / 1024)} KB`;
    refs.resultEmpty.hidden = true;
    refs.resultReady.hidden = false;
    setStatus("生成完成。");
  } catch (error) {
    setStatus(error.message || "生成失败。", true);
  } finally {
    state.generating = false;
    refs.resetButton.disabled = false;
    refs.toolSelect.disabled = false;
    syncGenerateButton();
  }
}

async function switchTool(targetMode) {
  if (targetMode === "mimo") {
    return;
  }
  const confirmed = window.confirm("切换到 IndexTTS 会停止当前 MiMoTTS 工具并重新打开 IndexTTS 页面。");
  if (!confirmed) {
    refs.toolSelect.value = "mimo";
    return;
  }

  refs.generateButton.disabled = true;
  refs.toolSelect.disabled = true;
  setStatus("正在切换到 IndexTTS。");
  try {
    const response = await fetch("/api/tts/switch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ target_mode: targetMode }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "切换失败");
    }
    const targetUrl = payload.target_url || "http://127.0.0.1:9000/";
    setStatus("切换请求已发送，新页面会自动打开。");
    window.open(targetUrl, "_blank");
    window.setTimeout(() => {
      window.close();
      window.location.href = targetUrl;
    }, 1200);
  } catch (error) {
    refs.toolSelect.disabled = false;
    refs.toolSelect.value = "mimo";
    setStatus(error.message || "切换失败。", true);
    syncGenerateButton();
  }
}

function resetForm() {
  refs.form.reset();
  updateCharCount();
  updateVoicePreview();
  clearResult();
  setStatus(state.configured ? "MiMo 已就绪。" : "请先填写 MiMo API Key。", !state.configured);
}

function bindEvents() {
  refs.apiKeyForm.addEventListener("submit", saveApiKey);
  refs.voiceInput.addEventListener("change", updateVoicePreview);
  refs.textInput.addEventListener("input", updateCharCount);
  refs.resetButton.addEventListener("click", resetForm);
  refs.form.addEventListener("submit", submitTts);
  refs.toolSelect.addEventListener("change", () => switchTool(refs.toolSelect.value));
}

bindEvents();
updateCharCount();
clearResult();
refreshStatus();

window.addEventListener("beforeunload", () => {
  if (state.voiceUrl) {
    URL.revokeObjectURL(state.voiceUrl);
  }
  if (state.resultUrl) {
    URL.revokeObjectURL(state.resultUrl);
  }
});
