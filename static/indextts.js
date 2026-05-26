const state = {
  health: null,
  voiceUrl: null,
  resultUrl: null,
  healthTimer: null,
  generating: false,
};

const refs = {
  form: document.querySelector("#ttsForm"),
  modelBadge: document.querySelector("#modelBadge"),
  versionBadge: document.querySelector("#versionBadge"),
  voiceInput: document.querySelector("#voiceInput"),
  voicePreviewWrap: document.querySelector("#voicePreviewWrap"),
  voicePreview: document.querySelector("#voicePreview"),
  voiceFileName: document.querySelector("#voiceFileName"),
  textInput: document.querySelector("#textInput"),
  charCount: document.querySelector("#charCount"),
  speedInput: document.querySelector("#speedInput"),
  speedValue: document.querySelector("#speedValue"),
  volumeInput: document.querySelector("#volumeInput"),
  volumeValue: document.querySelector("#volumeValue"),
  seedInput: document.querySelector("#seedInput"),
  temperatureInput: document.querySelector("#temperatureInput"),
  temperatureValue: document.querySelector("#temperatureValue"),
  topPInput: document.querySelector("#topPInput"),
  topPValue: document.querySelector("#topPValue"),
  topKInput: document.querySelector("#topKInput"),
  repetitionInput: document.querySelector("#repetitionInput"),
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

function setStatus(text, isError = false) {
  refs.statusText.textContent = text;
  refs.statusText.classList.toggle("error", isError);
}

function modelLoaded() {
  return Boolean(state.health && state.health.model_loaded);
}

function syncGenerateButton() {
  refs.generateButton.disabled = state.generating || !modelLoaded();
}

function applySupportedOptions(options) {
  document.querySelectorAll("[data-option]").forEach((field) => {
    const optionName = field.dataset.option;
    const enabled = options[optionName] !== false;
    field.classList.toggle("disabled-field", !enabled);
    field.querySelectorAll("input").forEach((input) => {
      input.disabled = !enabled || state.generating;
    });
  });
}

function updateRangeLabels() {
  refs.speedValue.textContent = `${Number(refs.speedInput.value).toFixed(2)}x`;
  refs.volumeValue.textContent = `${Number(refs.volumeInput.value)} dB`;
  refs.temperatureValue.textContent = Number(refs.temperatureInput.value).toFixed(2);
  refs.topPValue.textContent = Number(refs.topPInput.value).toFixed(2);
}

function updateCharCount() {
  const limit = Number(refs.textInput.maxLength || 1000);
  refs.charCount.textContent = `${refs.textInput.value.length} / ${limit}`;
}

function applyDefaults(defaults) {
  if (!defaults) return;
  refs.speedInput.value = defaults.speed ?? refs.speedInput.value;
  refs.volumeInput.value = defaults.volume_gain_db ?? refs.volumeInput.value;
  refs.temperatureInput.value = defaults.temperature ?? refs.temperatureInput.value;
  refs.topPInput.value = defaults.top_p ?? refs.topPInput.value;
  refs.topKInput.value = defaults.top_k ?? refs.topKInput.value;
  refs.repetitionInput.value = defaults.repetition_penalty ?? refs.repetitionInput.value;
  updateRangeLabels();
}

function renderHealth(payload) {
  state.health = payload;
  const loaded = Boolean(payload.model_loaded);
  setBadge(
    refs.modelBadge,
    loaded ? "模型: 已加载" : "模型: 未就绪",
    loaded ? "ok" : (payload.error ? "error" : "warning"),
  );
  setBadge(refs.versionBadge, `版本: ${payload.version || "unknown"}`, "muted");

  if (payload.max_text_length) {
    refs.textInput.maxLength = payload.max_text_length;
    updateCharCount();
  }

  applySupportedOptions(payload.supported_tts_options || {});
  if (loaded) {
    setStatus("模型已就绪。");
  } else if (payload.suggestion) {
    setStatus(payload.suggestion, true);
  } else if (payload.error) {
    setStatus(payload.error, true);
  } else {
    setStatus("模型正在加载。");
  }
  syncGenerateButton();
}

async function refreshHealth() {
  try {
    const response = await fetch("/health", { cache: "no-store" });
    if (!response.ok) {
      throw new Error("health request failed");
    }
    const payload = await response.json();
    renderHealth(payload);
  } catch (error) {
    state.health = null;
    setBadge(refs.modelBadge, "模型: 无响应", "error");
    setBadge(refs.versionBadge, "版本: unknown", "muted");
    setStatus(error.message || "无法连接 IndexTTS 服务。", true);
    syncGenerateButton();
  }
}

function startHealthPolling() {
  refreshHealth();
  state.healthTimer = window.setInterval(refreshHealth, 5000);
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

async function readErrorMessage(response) {
  const contentType = response.headers.get("content-type") || "";
  if (contentType.includes("application/json")) {
    const payload = await response.json();
    return payload.detail || JSON.stringify(payload);
  }
  const text = await response.text();
  return text || `HTTP ${response.status}`;
}

async function submitTts(event) {
  event.preventDefault();
  if (!modelLoaded()) {
    setStatus("模型未就绪。", true);
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
  applySupportedOptions(state.health?.supported_tts_options || {});
  setStatus("正在生成语音。");

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
    refs.downloadLink.download = `indextts-${Date.now()}.wav`;
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
    applySupportedOptions(state.health?.supported_tts_options || {});
    syncGenerateButton();
  }
}

function resetForm() {
  refs.form.reset();
  applyDefaults(state.health?.default_tts_options);
  updateRangeLabels();
  updateCharCount();
  updateVoicePreview();
  clearResult();
  setStatus(modelLoaded() ? "模型已就绪。" : "等待模型状态。");
}

function bindEvents() {
  refs.voiceInput.addEventListener("change", updateVoicePreview);
  refs.textInput.addEventListener("input", updateCharCount);
  refs.speedInput.addEventListener("input", updateRangeLabels);
  refs.volumeInput.addEventListener("input", updateRangeLabels);
  refs.temperatureInput.addEventListener("input", updateRangeLabels);
  refs.topPInput.addEventListener("input", updateRangeLabels);
  refs.resetButton.addEventListener("click", resetForm);
  refs.form.addEventListener("submit", submitTts);
}

bindEvents();
updateRangeLabels();
updateCharCount();
clearResult();
startHealthPolling();

window.addEventListener("beforeunload", () => {
  if (state.healthTimer) {
    window.clearInterval(state.healthTimer);
  }
  if (state.voiceUrl) {
    URL.revokeObjectURL(state.voiceUrl);
  }
  if (state.resultUrl) {
    URL.revokeObjectURL(state.resultUrl);
  }
});
