    // Upload form logic
    const dropArea = document.getElementById("uploadForm");
    const fileInput = document.getElementById("fileElem");
    const messageElem = document.getElementById("message");
    const preview = document.getElementById("preview");
    const progressBar = document.getElementById("progressBar");
    dropArea.addEventListener("dragover", (e) => { e.preventDefault(); dropArea.classList.add("dragover"); });
    dropArea.addEventListener("dragleave", () => { dropArea.classList.remove("dragover"); });
    dropArea.addEventListener("drop", (e) => {
      e.preventDefault();
      dropArea.classList.remove("dragover");
      if (e.dataTransfer.files.length > 0) {
        fileInput.files = e.dataTransfer.files;
        showPreview(e.dataTransfer.files[0]);
      }
    });
    fileInput.addEventListener("change", () => {
      if (fileInput.files.length > 0) {
        showPreview(fileInput.files[0]);
      }
    });
    dropArea.addEventListener("submit", (e) => {
      e.preventDefault();
      messageElem.textContent = "";
      progressBar.style.width = "0%";
      if (fileInput.files.length === 0) {
        messageElem.textContent = "Please select a file first.";
        return;
      }
      const formData = new FormData();
      formData.append("file", fileInput.files[0]);
      const xhr = new XMLHttpRequest();
      xhr.open("POST", "/upload", true);
      xhr.upload.onprogress = (e) => {
        if (e.lengthComputable) {
          const percent = (e.loaded / e.total) * 100;
          progressBar.style.width = percent + "%";
        }
      };
      xhr.onload = () => {
        if (xhr.status === 200) {
          messageElem.textContent = "Upload successful!";
          fileInput.value = "";
        } else {
          messageElem.textContent = "Upload failed. (" + xhr.status + ")";
        }
        progressBar.style.width = "0%";
      };
      xhr.onerror = () => {
        messageElem.textContent = "Upload failed (network error).";
        progressBar.style.width = "0%";
      };
      xhr.send(formData);
    });
    function showPreview(file) {
      preview.innerHTML = "";
      if (file.type.startsWith("image/")) {
        const reader = new FileReader();
        reader.onload = (e) => {
          const img = document.createElement("img");
          img.src = e.target.result;
          preview.appendChild(img);
        };
        reader.readAsDataURL(file);
      }
    }

    // Chat logic (wrapped to ensure DOM is loaded)
    window.addEventListener('DOMContentLoaded', () => {
      const chatForm = document.getElementById("chatForm");
      const chatInput = document.getElementById("chatInput");
      const chatMessages = document.getElementById("chatMessages");

      chatForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const text = chatInput.value.trim();
        if (!text) return;
        await fetch('/chat', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: 'message=' + encodeURIComponent(text)
        });
        chatInput.value = '';
        loadMessages();
      });

      async function loadMessages() {
        const resp = await fetch('/chat');
        if (!resp.ok) return;
        const data = await resp.json();
        chatMessages.innerHTML = '';
        data.messages.forEach(entry => {
          const div = document.createElement('div');
          div.classList.add('msg');
          const ts = document.createElement('span');
          ts.classList.add('timestamp');
          ts.textContent = '[' + entry.timestamp + ']';
          const txt = document.createElement('span');
          txt.textContent = entry.message;
          div.appendChild(ts);
          div.appendChild(txt);
          chatMessages.appendChild(div);
        });
        chatMessages.scrollTop = chatMessages.scrollHeight;
      }

      loadMessages();
      setInterval(loadMessages, 5000);
    });