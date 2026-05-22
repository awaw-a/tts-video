const form = document.querySelector("#generateForm");
const submitButton = document.querySelector("#submitButton");
const statusText = document.querySelector("#statusText");
const resultPanel = document.querySelector("#resultPanel");
const taskText = document.querySelector("#taskText");
const downloadLink = document.querySelector("#downloadLink");

function setStatus(message, isError = false) {
  statusText.textContent = message;
  statusText.classList.toggle("error", isError);
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const formData = new FormData(form);
  submitButton.disabled = true;
  resultPanel.hidden = true;
  setStatus("生成中，请稍候...");

  try {
    const response = await fetch("/api/generate", {
      method: "POST",
      body: formData,
    });

    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.detail || "生成失败");
    }

    taskText.textContent = `任务 ID：${payload.task_id}`;
    downloadLink.href = payload.video_url;
    resultPanel.hidden = false;
    setStatus("生成完成");
  } catch (error) {
    setStatus(error.message || "生成失败", true);
  } finally {
    submitButton.disabled = false;
  }
});

