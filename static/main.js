const state = {
  config: null,
  imageUrl: null,
  audioUrl: null,
  stageTimer: null,
  healthTimer: null,
  selectedTtsBackend: null,
  mimoConfigured: false,
};

const refs = {
  form: document.querySelector("#generateForm"),
  backendBadge: document.querySelector("#backendBadge"),
  connectionBadge: document.querySelector("#connectionBadge"),
  imageInput: document.querySelector("#imageInput"),
  audioInput: document.querySelector("#audioInput"),
  imageFileName: document.querySelector("#imageFileName"),
  audioFileName: document.querySelector("#audioFileName"),
  videoPreviewFrame: document.querySelector("#videoPreviewFrame"),
  previewBg: document.querySelector("#previewBg"),
  imagePreview: document.querySelector("#imagePreview"),
  imagePlaceholder: document.querySelector("#imagePlaceholder"),
  subtitleOverlay: document.querySelector("#subtitleOverlay"),
  previewRatioBadge: document.querySelector("#previewRatioBadge"),
  audioPreview: document.querySelector("#audioPreview"),
  audioPreviewWrap: document.querySelector("#audioPreviewWrap"),
  audioPlaceholder: document.querySelector("#audioPlaceholder"),
  audioPreviewName: document.querySelector("#audioPreviewName"),
  scriptInput: document.querySelector("#scriptInput"),
  scriptHint: document.querySelector("#scriptHint"),
  charCount: document.querySelector("#charCount"),
  clearScriptButton: document.querySelector("#clearScriptButton"),
  aspectRatio: document.querySelector("#aspectRatio"),
  backgroundStyle: document.querySelector("#backgroundStyle"),
  subtitleStyle: document.querySelector("#subtitleStyle"),
  subtitleEnabled: document.querySelector("#subtitleEnabled"),
  subtitleMaxChars: document.querySelector("#subtitleMaxChars"),
  subtitleMaxCharsValue: document.querySelector("#subtitleMaxCharsValue"),
  subtitleList: document.querySelector("#subtitleList"),
  subtitleCount: document.querySelector("#subtitleCount"),
  ttsModeText: document.querySelector("#ttsModeText"),
  ttsBackendSelect: document.querySelector("#ttsBackendSelect"),
  mockNotice: document.querySelector("#mockNotice"),
  mimoKeyPanel: document.querySelector("#mimoKeyPanel"),
  mimoKeyForm: document.querySelector("#mimoKeyForm"),
  mimoApiKeyInput: document.querySelector("#mimoApiKeyInput"),
  saveMimoKeyButton: document.querySelector("#saveMimoKeyButton"),
  mimoControls: document.querySelector("#mimoControls"),
  mimoStylePrompt: document.querySelector("#mimoStylePrompt"),
  ttsControls: document.querySelector("#ttsControls"),
  ttsSpeed: document.querySelector("#ttsSpeed"),
  speedValue: document.querySelector("#speedValue"),
  ttsVolumeGain: document.querySelector("#ttsVolumeGain"),
  volumeValue: document.querySelector("#volumeValue"),
  ttsTemperature: document.querySelector("#ttsTemperature"),
  temperatureValue: document.querySelector("#temperatureValue"),
  ttsTopP: document.querySelector("#ttsTopP"),
  topPValue: document.querySelector("#topPValue"),
  submitButton: document.querySelector("#submitButton"),
  resetButton: document.querySelector("#resetButton"),
  statusText: document.querySelector("#statusText"),
  resultCard: document.querySelector("#resultCard"),
  resultPlaceholder: document.querySelector("#resultPlaceholder"),
  resultContent: document.querySelector("#resultContent"),
  resultVideo: document.querySelector("#resultVideo"),
  taskInfo: document.querySelector("#taskInfo"),
  downloadLink: document.querySelector("#downloadLink"),
};

function setStatus(message, isError = false) {
  refs.statusText.textContent = message;
  refs.statusText.classList.toggle("error", isError);
}

function setBadge(element, text, kind = "muted") {
  element.textContent = text;
  element.className = `badge ${kind}`;
}

function getSelectedTtsBackend() {
  return refs.ttsBackendSelect?.value || state.selectedTtsBackend || state.config?.tts_backend || "mock";
}

function getBackendLabel(backend) {
  const backendConfig = (state.config?.tts_backends || []).find((item) => item.value === backend);
  return backendConfig?.label || backend;
}

function getSupportedTtsOptions(backend) {
  return state.config?.supported_tts_options_by_backend?.[backend] || state.config?.supported_tts_options || {};
}

function renderTtsStatus(backend, indexttsHealth = null, mimoStatus = null) {
  state.selectedTtsBackend = backend;
  const backendLabel = getBackendLabel(backend);
  setBadge(refs.backendBadge, `TTS: ${backendLabel}`, backend === "mock" ? "muted" : "ok");

  const currentMimoStatus = mimoStatus || state.config?.mimo_api || {};
  state.mimoConfigured = Boolean(currentMimoStatus.configured);
  refs.mockNotice.hidden = backend !== "mock";
  refs.ttsControls.hidden = backend !== "indextts_api";
  refs.mimoControls.hidden = backend !== "mimo_api";
  refs.mimoKeyPanel.hidden = backend !== "mimo_api" || state.mimoConfigured;
  applySupportedTtsOptions(getSupportedTtsOptions(backend));

  if (backend === "indextts_api") {
    const available = Boolean(indexttsHealth?.available || indexttsHealth?.model_loaded || state.config?.indextts_available);
    const hasError = !available && Boolean(indexttsHealth?.error || indexttsHealth?.error_code);
    setBadge(
      refs.connectionBadge,
      available ? "IndexTTS: 已连接" : (hasError ? "IndexTTS: 启动失败" : "IndexTTS: 启动中"),
      available ? "ok" : (hasError ? "error" : "warning"),
    );
    if (available) {
      refs.ttsModeText.textContent = "当前使用 IndexTTS API 模式，服务已连接。";
    } else if (hasError) {
      refs.ttsModeText.textContent = indexttsHealth?.suggestion || "IndexTTS 模型加载失败，请查看 logs/indextts.log。";
    } else {
      refs.ttsModeText.textContent = "当前使用 IndexTTS API 模式，正在等待模型加载完成。";
    }
    return;
  }

  if (backend === "mimo_api") {
    setBadge(
      refs.connectionBadge,
      state.mimoConfigured ? "MiMo: 已配置" : "MiMo: 需要 Key",
      state.mimoConfigured ? "ok" : "warning",
    );
    refs.ttsModeText.textContent = state.mimoConfigured
      ? "当前使用 MiMoTTS 音色克隆，生成时会直接调用 MiMo API。"
      : "当前使用 MiMoTTS 音色克隆，请先保存 API Key。";
    return;
  }

  setBadge(refs.connectionBadge, "TTS: mock", "muted");
  refs.ttsModeText.textContent = "当前为 mock 模式。";
}

async function refreshTtsHealth() {
  if (!state.config) {
    return;
  }

  try {
    const response = await fetch("/api/health", { cache: "no-store" });
    if (!response.ok) {
      throw new Error("health request failed");
    }

    const payload = await response.json();
    const indexttsHealth = payload.indextts_api || {};
    const mimoStatus = payload.mimo_api || {};
    state.config.tts_backend = payload.tts_backend || state.config.tts_backend;
    state.config.indextts_available = Boolean(indexttsHealth.available || indexttsHealth.model_loaded);
    state.config.indextts_api = indexttsHealth;
    state.config.mimo_api = mimoStatus;
    state.mimoConfigured = Boolean(mimoStatus.configured);
    if (indexttsHealth.supported_tts_options) {
      state.config.supported_tts_options_by_backend = {
        ...(state.config.supported_tts_options_by_backend || {}),
        indextts_api: {
          ...(state.config.supported_tts_options_by_backend?.indextts_api || {}),
          ...indexttsHealth.supported_tts_options,
        },
      };
    }
    renderTtsStatus(getSelectedTtsBackend(), indexttsHealth, mimoStatus);
  } catch (error) {
    renderTtsStatus(getSelectedTtsBackend(), { available: false, error: error.message }, state.config.mimo_api);
  }
}

function startTtsHealthPolling() {
  if (state.healthTimer) {
    window.clearInterval(state.healthTimer);
    state.healthTimer = null;
  }

  refreshTtsHealth();
  state.healthTimer = window.setInterval(refreshTtsHealth, 5000);
}

async function loadConfig() {
  try {
    const response = await fetch("/api/config");
    if (!response.ok) {
      throw new Error("无法读取配置");
    }
    state.config = await response.json();
    renderConfig();
    startTtsHealthPolling();
  } catch (error) {
    setBadge(refs.backendBadge, "TTS: unknown", "error");
    setBadge(refs.connectionBadge, "IndexTTS: 未知", "error");
    refs.ttsModeText.textContent = error.message || "配置读取失败";
  }
}

function renderConfig() {
  const config = state.config;
  const backend = config.tts_backend || "mock";

  renderSelectOptions(refs.ttsBackendSelect, config.tts_backends || []);
  if ([...refs.ttsBackendSelect.options].some((option) => option.value === backend)) {
    refs.ttsBackendSelect.value = backend;
  }
  state.selectedTtsBackend = refs.ttsBackendSelect.value || backend;
  state.mimoConfigured = Boolean(config.mimo_api?.configured);

  renderTtsStatus(state.selectedTtsBackend, config.indextts_api || { available: config.indextts_available }, config.mimo_api);

  renderAspectOptions(config.aspect_ratios || []);
  renderSelectOptions(refs.backgroundStyle, config.background_styles || []);
  refs.aspectRatio.value = config.default_aspect_ratio || "16:9";
  refs.backgroundStyle.value = config.default_background_style || "blur";
  refs.subtitleStyle.value = config.default_subtitle_style || "yellow_black";
  refs.subtitleMaxChars.value = config.default_max_chars_per_line || 18;

  updateAllPreviews();
}

function renderSelectOptions(selectElement, options) {
  if (!selectElement || !options.length) return;

  selectElement.innerHTML = "";
  options.forEach((item) => {
    const option = document.createElement("option");
    option.value = item.value;
    option.textContent = item.label;
    selectElement.appendChild(option);
  });
}

function renderAspectOptions(aspectRatios) {
  renderSelectOptions(refs.aspectRatio, aspectRatios);
}

function applySupportedTtsOptions(options) {
  document.querySelectorAll("[data-option]").forEach((field) => {
    const name = field.dataset.option;
    const enabled = Boolean(options[name]);
    field.classList.toggle("disabled-field", !enabled);
    field.querySelectorAll("input, select").forEach((input) => {
      input.disabled = !enabled;
    });
  });
}

function updateFilePreview(input, kind) {
  const file = input.files && input.files[0];
  if (kind === "image") {
    if (state.imageUrl) URL.revokeObjectURL(state.imageUrl);
    if (!file) {
      state.imageUrl = null;
      refs.imageFileName.textContent = "未选择文件";
      refs.videoPreviewFrame.classList.remove("preview-ready");
      refs.previewBg.hidden = true;
      refs.previewBg.style.backgroundImage = "";
      refs.imagePreview.hidden = true;
      refs.imagePreview.removeAttribute("src");
      refs.subtitleOverlay.hidden = true;
      refs.imagePlaceholder.hidden = false;
      refs.imagePlaceholder.textContent = "上传角色图片后在这里预览最终画面";
      updateBackgroundPreview();
      return;
    }
    state.imageUrl = URL.createObjectURL(file);
    refs.imageFileName.textContent = file.name;
    refs.videoPreviewFrame.classList.remove("preview-ready");
    refs.previewBg.hidden = true;
    refs.previewBg.style.backgroundImage = `url("${state.imageUrl}")`;
    refs.imagePreview.hidden = true;
    refs.subtitleOverlay.hidden = true;
    refs.imagePlaceholder.hidden = false;
    refs.imagePlaceholder.textContent = "正在加载图片预览……";
    refs.imagePreview.onload = () => {
      refs.previewBg.hidden = false;
      refs.imagePreview.hidden = false;
      refs.imagePlaceholder.hidden = true;
      refs.videoPreviewFrame.classList.add("preview-ready");
      updateBackgroundPreview();
      updateSubtitleStyle();
    };
    refs.imagePreview.onerror = () => {
      refs.videoPreviewFrame.classList.remove("preview-ready");
      refs.previewBg.hidden = true;
      refs.previewBg.style.backgroundImage = "";
      refs.imagePreview.hidden = true;
      refs.subtitleOverlay.hidden = true;
      refs.imagePlaceholder.hidden = false;
      refs.imagePlaceholder.textContent = "图片预览失败，请确认文件格式为 png / jpg / jpeg / webp。";
      updateBackgroundPreview();
    };
    refs.imagePreview.src = state.imageUrl;
  }

  if (kind === "audio") {
    if (state.audioUrl) URL.revokeObjectURL(state.audioUrl);
    if (!file) {
      state.audioUrl = null;
      refs.audioFileName.textContent = "未选择文件";
      refs.audioPreviewWrap.hidden = true;
      refs.audioPreview.removeAttribute("src");
      refs.audioPlaceholder.hidden = false;
      return;
    }
    state.audioUrl = URL.createObjectURL(file);
    refs.audioFileName.textContent = file.name;
    refs.audioPreviewName.textContent = file.name;
    refs.audioPreview.src = state.audioUrl;
    refs.audioPreviewWrap.hidden = false;
    refs.audioPlaceholder.hidden = true;
  }
}

function splitScript(text, maxCjkChars) {
  const clean = text.trim();
  if (!clean) return [];

  const sentences = [];
  let buffer = "";
  const punctuation = new Set(["。", "！", "？", "；", ".", "!", "?", ";"]);
  for (const char of clean.replace(/\s+/g, " ")) {
    buffer += char;
    if (punctuation.has(char)) {
      sentences.push(buffer.trim());
      buffer = "";
    }
  }
  if (buffer.trim()) sentences.push(buffer.trim());

  const result = [];
  const maxAsciiChars = maxCjkChars * 2;
  for (const sentence of sentences) {
    const limit = /[\u4e00-\u9fff]/.test(sentence) ? maxCjkChars : maxAsciiChars;
    if (sentence.length <= limit) {
      result.push(sentence);
      continue;
    }
    for (let i = 0; i < sentence.length; i += limit) {
      const chunk = sentence.slice(i, i + limit).trim();
      if (chunk) result.push(chunk);
    }
  }
  return result;
}

function updateSubtitlePreview() {
  const maxChars = Number(refs.subtitleMaxChars.value || 18);
  const lines = splitScript(refs.scriptInput.value, maxChars);
  refs.subtitleCount.textContent = `${lines.length} 行`;
  refs.subtitleList.innerHTML = "";

  if (!lines.length) {
    const li = document.createElement("li");
    li.className = "empty-line";
    li.textContent = "输入文案后显示字幕拆分。";
    refs.subtitleList.appendChild(li);
  } else {
    lines.forEach((line) => {
      const li = document.createElement("li");
      li.textContent = line;
      refs.subtitleList.appendChild(li);
    });
  }

  refs.subtitleOverlay.textContent = lines[0] || "字幕效果预览";
}

function updateSubtitleStyle() {
  const styleClass = {
    white_black: "style-white-black",
    yellow_black: "style-yellow-black",
    bilibili_large: "style-bilibili-large",
  }[refs.subtitleStyle.value] || "style-yellow-black";
  const hasImage = refs.videoPreviewFrame.classList.contains("preview-ready");
  const showSubtitle = hasImage && refs.subtitleEnabled.checked;

  refs.subtitleOverlay.className = `preview-subtitle ${styleClass}`;
  refs.subtitleOverlay.hidden = !showSubtitle;
  refs.videoPreviewFrame.classList.toggle("has-subtitle-band", showSubtitle && refs.subtitleStyle.value === "bilibili_large");
}

function updateAspectPreview() {
  refs.videoPreviewFrame.classList.remove("ratio-16-9", "ratio-4-3", "ratio-9-16", "ratio-3-4", "ratio-1-1");
  const ratioClass = {
    "16:9": "ratio-16-9",
    "4:3": "ratio-4-3",
    "9:16": "ratio-9-16",
    "3:4": "ratio-3-4",
    "1:1": "ratio-1-1",
  }[refs.aspectRatio.value] || "ratio-16-9";
  refs.videoPreviewFrame.classList.add(ratioClass);
  refs.previewRatioBadge.textContent = refs.aspectRatio.value;
}

function updateBackgroundPreview() {
  const style = refs.backgroundStyle?.value || "blur";
  const bgClasses = ["bg-blur", "bg-white", "bg-red", "bg-blue", "bg-gradient-blue", "bg-gradient-red"];
  refs.videoPreviewFrame.classList.remove(...bgClasses);
  refs.videoPreviewFrame.classList.add(`bg-${style.replace("_", "-")}`);

  const hasLoadedImage = refs.videoPreviewFrame.classList.contains("preview-ready") && Boolean(state.imageUrl);
  const shouldUseBlurImage = style === "blur" && hasLoadedImage;
  refs.previewBg.hidden = !shouldUseBlurImage;
  refs.previewBg.style.backgroundImage = state.imageUrl ? `url("${state.imageUrl}")` : "";
}

function updateCharCount() {
  const count = refs.scriptInput.value.length;
  refs.charCount.textContent = `${count} / 1000`;
  refs.scriptHint.textContent = count > 900 ? "文案较长，生成时间可能增加。" : "建议控制在 1000 字以内。";
}

function updateRangeLabels() {
  refs.subtitleMaxCharsValue.textContent = refs.subtitleMaxChars.value;
  refs.speedValue.textContent = `${Number(refs.ttsSpeed.value).toFixed(2)}x`;
  refs.volumeValue.textContent = `${Number(refs.ttsVolumeGain.value)} dB`;
  refs.temperatureValue.textContent = Number(refs.ttsTemperature.value).toFixed(2);
  refs.topPValue.textContent = Number(refs.ttsTopP.value).toFixed(2);
}

function updateAllPreviews() {
  updateRangeLabels();
  updateCharCount();
  updateSubtitlePreview();
  updateSubtitleStyle();
  updateAspectPreview();
  updateBackgroundPreview();
}

function startStageTicker() {
  const stages = [
    "正在上传素材……",
    "正在生成语音，请稍等……",
    "正在生成字幕……",
    "正在合成视频……",
  ];
  let index = 0;
  setStatus(stages[index]);
  state.stageTimer = window.setInterval(() => {
    index = Math.min(index + 1, stages.length - 1);
    setStatus(stages[index]);
  }, 4500);
}

function stopStageTicker() {
  if (state.stageTimer) {
    window.clearInterval(state.stageTimer);
    state.stageTimer = null;
  }
}

function clearResult() {
  refs.resultContent.hidden = true;
  refs.resultPlaceholder.hidden = false;
  refs.resultVideo.removeAttribute("src");
  refs.resultVideo.load();
  refs.taskInfo.textContent = "";
  refs.downloadLink.href = "#";
}

function handleTtsBackendChange() {
  const backend = getSelectedTtsBackend();
  state.selectedTtsBackend = backend;
  renderTtsStatus(backend, state.config?.indextts_api, state.config?.mimo_api);
  if (backend === "mimo_api" && !state.mimoConfigured) {
    setStatus("请先保存 MiMo API Key。", true);
  } else {
    setStatus("等待输入素材。");
  }
}

async function saveMimoKey() {
  const apiKey = refs.mimoApiKeyInput.value.trim();
  if (!apiKey) {
    setStatus("请输入 MiMo API Key。", true);
    refs.mimoApiKeyInput.focus();
    return;
  }

  refs.saveMimoKeyButton.disabled = true;
  try {
    const response = await fetch("/api/mimo/key", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: apiKey }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "MiMo API Key 保存失败");
    }

    state.config = state.config || {};
    state.config.mimo_api = {
      ...(state.config.mimo_api || {}),
      configured: true,
    };
    state.mimoConfigured = true;
    refs.mimoApiKeyInput.value = "";
    renderTtsStatus(getSelectedTtsBackend(), state.config.indextts_api, state.config.mimo_api);
    setStatus(payload.message || "MiMo API Key 已保存。");
    refreshTtsHealth();
  } catch (error) {
    setStatus(error.message || "MiMo API Key 保存失败", true);
  } finally {
    refs.saveMimoKeyButton.disabled = false;
  }
}

async function submitGenerate(event) {
  event.preventDefault();
  clearResult();

  if (!refs.imageInput.files.length || !refs.audioInput.files.length || !refs.scriptInput.value.trim()) {
    setStatus("请先选择图片、音频并输入文案。", true);
    return;
  }

  const selectedBackend = getSelectedTtsBackend();
  if (selectedBackend === "mimo_api" && !state.mimoConfigured) {
    setStatus("请先保存 MiMo API Key，再生成视频。", true);
    refs.mimoApiKeyInput.focus();
    return;
  }

  const formData = new FormData(refs.form);
  formData.set("subtitle_enabled", refs.subtitleEnabled.checked ? "true" : "false");
  formData.set("tts_backend", selectedBackend);
  formData.set("tts_style_prompt", refs.mimoStylePrompt.value || "");

  refs.submitButton.disabled = true;
  refs.resetButton.disabled = true;
  startStageTicker();

  try {
    const response = await fetch("/api/generate", {
      method: "POST",
      body: formData,
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "生成失败");
    }

    const videoUrl = `${payload.video_url}?t=${Date.now()}`;
    refs.resultVideo.src = videoUrl;
    refs.downloadLink.href = payload.video_url;
    refs.taskInfo.textContent = `任务 ID：${payload.task_id} · TTS：${payload.audio_backend}`;
    refs.resultPlaceholder.hidden = true;
    refs.resultContent.hidden = false;
    setStatus(payload.message || "已完成");
    refs.resultCard.scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    setStatus(error.message || "生成失败", true);
  } finally {
    stopStageTicker();
    refs.submitButton.disabled = false;
    refs.resetButton.disabled = false;
  }
}

function resetForm() {
  refs.form.reset();
  refs.aspectRatio.value = state.config?.default_aspect_ratio || "16:9";
  refs.backgroundStyle.value = state.config?.default_background_style || "blur";
  refs.subtitleStyle.value = state.config?.default_subtitle_style || "yellow_black";
  refs.subtitleMaxChars.value = state.config?.default_max_chars_per_line || 18;
  refs.ttsBackendSelect.value = state.config?.tts_backend || "mock";
  state.selectedTtsBackend = refs.ttsBackendSelect.value;
  renderTtsStatus(state.selectedTtsBackend, state.config?.indextts_api, state.config?.mimo_api);
  updateFilePreview(refs.imageInput, "image");
  updateFilePreview(refs.audioInput, "audio");
  updateAllPreviews();
  clearResult();
  setStatus("等待输入素材。");
}

function bindEvents() {
  refs.imageInput.addEventListener("change", () => updateFilePreview(refs.imageInput, "image"));
  refs.audioInput.addEventListener("change", () => updateFilePreview(refs.audioInput, "audio"));
  refs.scriptInput.addEventListener("input", updateAllPreviews);
  refs.clearScriptButton.addEventListener("click", () => {
    refs.scriptInput.value = "";
    updateAllPreviews();
  });
  refs.aspectRatio.addEventListener("change", updateAspectPreview);
  refs.backgroundStyle.addEventListener("change", updateBackgroundPreview);
  refs.subtitleStyle.addEventListener("change", updateSubtitleStyle);
  refs.subtitleEnabled.addEventListener("change", updateSubtitleStyle);
  refs.subtitleMaxChars.addEventListener("input", updateAllPreviews);
  refs.ttsBackendSelect.addEventListener("change", handleTtsBackendChange);
  refs.saveMimoKeyButton.addEventListener("click", saveMimoKey);
  refs.mimoApiKeyInput.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      saveMimoKey();
    }
  });
  refs.ttsSpeed.addEventListener("input", updateRangeLabels);
  refs.ttsVolumeGain.addEventListener("input", updateRangeLabels);
  refs.ttsTemperature.addEventListener("input", updateRangeLabels);
  refs.ttsTopP.addEventListener("input", updateRangeLabels);
  refs.form.addEventListener("submit", submitGenerate);
  refs.resetButton.addEventListener("click", resetForm);
}

bindEvents();
updateAllPreviews();
loadConfig();

window.addEventListener("beforeunload", () => {
  if (state.healthTimer) {
    window.clearInterval(state.healthTimer);
  }
});
