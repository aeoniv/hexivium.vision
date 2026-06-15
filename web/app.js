document.addEventListener("DOMContentLoaded", () => {
    // UI Elements
    const videoUploadBox = document.getElementById("video-upload-box");
    const videoInput = document.getElementById("video-input");
    const videoFileName = document.getElementById("video-file-name");
    const videoUploadProgress = document.getElementById("video-upload-progress");

    const imageUploadBox = document.getElementById("image-upload-box");
    const imageInput = document.getElementById("image-input");
    const imageFileName = document.getElementById("image-file-name");
    const imageUploadProgress = document.getElementById("image-upload-progress");

    const paramSigma = document.getElementById("param-sigma");
    const valSigma = document.getElementById("val-sigma");
    const paramSteps = document.getElementById("param-steps");
    const valSteps = document.getElementById("val-steps");
    const paramCfg = document.getElementById("param-cfg");
    const valCfg = document.getElementById("val-cfg");

    const paramLength = document.getElementById("param-length");
    const valLength = document.getElementById("val-length");
    const paramFps = document.getElementById("param-fps");
    const valFps = document.getElementById("val-fps");
    const paramPrompt = document.getElementById("param-prompt");
    const paramNegative = document.getElementById("param-negative");

    // Default creative direction (matches workflow_qi_pipeline.json node 10)
    const DEFAULT_PROMPT = "Cinematic 8k video, medium wide shot, a athletic practitioner performing sacred Tai Chi movements. Photorealistic bare skin texture with visible muscle definition, subtle skin pores, and natural body contours. Golden volumetric lighting cuts through a clean, minimalist studio background, catching the precise edge of the turning torso. Swirling bioluminescent particles of liquid light and auric currents flow smoothly along the pathways of the meridians and up the spine, pulsing with every slow kinetic transition. The energetic trails wrap seamlessly around the moving boundaries of the body, shifting from a warm glowing amber at the lower dantian base into an ethereal radiant white as it ascends the spinal column. Flowing motion, highly detailed anatomy, hyper-realistic physics, clean framing, shallow depth of field, filmic quality.";
    const DEFAULT_NEGATIVE = "text, watermark, logo, deformed limbs, floating joints, extra fingers, clothing, underwear, fabrics, swimming trunks, rubbery skin, sudden morphing, rapid camera cuts, motion blur artifacts, flat lighting, background noise, low resolution, plastic texture, cartoon, 3D render artifact.";
    if (paramPrompt && !paramPrompt.value) paramPrompt.value = DEFAULT_PROMPT;
    if (paramNegative && !paramNegative.value) paramNegative.value = DEFAULT_NEGATIVE;

    const launchBtn = document.getElementById("launch-btn");
    const progressBar = document.getElementById("progress-bar");
    const progressPct = document.getElementById("progress-pct");
    const progressLabel = document.getElementById("progress-label");

    const nodeWham = document.getElementById("node-wham");
    const nodeBlender = document.getElementById("node-blender");
    const nodeControlnet = document.getElementById("node-controlnet");
    const nodeComfyui = document.getElementById("node-comfyui");

    const conn1 = document.getElementById("conn-1");
    const conn2 = document.getElementById("conn-2");
    const conn3 = document.getElementById("conn-3");

    const consoleStream = document.getElementById("console-stream");
    const clearLogsBtn = document.getElementById("clear-logs-btn");
    const videoContainer = document.getElementById("video-container");
    const outputVideo = document.getElementById("output-video");

    let isVideoUploaded = false;
    let isImageUploaded = false;
    let isPipelineRunning = false;
    let pollInterval = null;
    let lastLogLength = 0;

    // Sliders dynamic value display
    paramSigma.addEventListener("input", (e) => valSigma.textContent = parseFloat(e.target.value).toFixed(1));
    paramSteps.addEventListener("input", (e) => valSteps.textContent = e.target.value);
    paramCfg.addEventListener("input", (e) => valCfg.textContent = parseFloat(e.target.value).toFixed(1));
    paramLength.addEventListener("change", (e) => {
        valLength.textContent = e.target.value === "81" ? "Full clip" : `≤${e.target.value} frames`;
    });
    paramFps.addEventListener("change", (e) => valFps.textContent = `${e.target.value} fps`);

    // Upload Box Click Handler
    videoUploadBox.addEventListener("click", () => videoInput.click());
    imageUploadBox.addEventListener("click", () => imageInput.click());

    // File selection change handlers
    videoInput.addEventListener("change", (e) => {
        if (e.target.files.length > 0) handleFileUpload(e.target.files[0], "/api/upload-video", videoFileName, videoUploadProgress, (success) => {
            isVideoUploaded = success;
            checkReadyState();
        });
    });

    imageInput.addEventListener("change", (e) => {
        if (e.target.files.length > 0) handleFileUpload(e.target.files[0], "/api/upload-image", imageFileName, imageUploadProgress, (success) => {
            isImageUploaded = success;
            checkReadyState();
        });
    });

    // Drag and Drop support
    setupDragAndDrop(videoUploadBox, (file) => {
        if (file.type === "video/mp4") {
            handleFileUpload(file, "/api/upload-video", videoFileName, videoUploadProgress, (success) => {
                isVideoUploaded = success;
                checkReadyState();
            });
        } else {
            appendLog("[ERROR] Video must be an MP4 file.", "error-log");
        }
    });

    setupDragAndDrop(imageUploadBox, (file) => {
        if (file.type.startsWith("image/")) {
            handleFileUpload(file, "/api/upload-image", imageFileName, imageUploadProgress, (success) => {
                isImageUploaded = success;
                checkReadyState();
            });
        } else {
            appendLog("[ERROR] Image must be a valid PNG or JPEG.", "error-log");
        }
    });

    function setupDragAndDrop(element, callback) {
        element.addEventListener("dragover", (e) => {
            e.preventDefault();
            element.classList.add("dragover");
        });

        element.addEventListener("dragleave", () => {
            element.classList.remove("dragover");
        });

        element.addEventListener("drop", (e) => {
            e.preventDefault();
            element.classList.remove("dragover");
            if (e.dataTransfer.files.length > 0) {
                callback(e.dataTransfer.files[0]);
            }
        });
    }

    // General Upload Handler
    function handleFileUpload(file, url, nameEl, progressEl, callback) {
        nameEl.textContent = `Uploading: ${file.name}...`;
        progressEl.style.width = "0%";
        
        const xhr = new XMLHttpRequest();
        const formData = new FormData();
        formData.append("file", file);

        xhr.upload.addEventListener("progress", (e) => {
            if (e.lengthComputable) {
                const percent = (e.loaded / e.total) * 100;
                progressEl.style.width = `${percent}%`;
            }
        });

        xhr.addEventListener("load", () => {
            if (xhr.status === 200) {
                nameEl.textContent = `${file.name} (Uploaded)`;
                progressEl.style.width = "100%";
                appendLog(`[SUCCESS] File uploaded: ${file.name}`, "success-log");
                callback(true);
            } else {
                nameEl.textContent = "Upload failed.";
                progressEl.style.width = "0%";
                appendLog(`[ERROR] File upload failed: ${xhr.responseText}`, "error-log");
                callback(false);
            }
        });

        xhr.addEventListener("error", () => {
            nameEl.textContent = "Upload failed.";
            progressEl.style.width = "0%";
            appendLog("[ERROR] File upload failed due to connection error.", "error-log");
            callback(false);
        });

        xhr.open("POST", url);
        xhr.send(formData);
    }

    function checkReadyState() {
        if (isVideoUploaded && isImageUploaded && !isPipelineRunning) {
            launchBtn.removeAttribute("disabled");
        } else {
            launchBtn.setAttribute("disabled", "true");
        }
    }

    // Launch Pipeline
    launchBtn.addEventListener("click", () => {
        if (isPipelineRunning) return;
        
        launchBtn.setAttribute("disabled", "true");
        launchBtn.classList.add("running");
        launchBtn.querySelector(".btn-text").textContent = "TRANSMUTING VITAL FORCE...";
        
        // Disable sliders
        paramSigma.setAttribute("disabled", "true");
        paramSteps.setAttribute("disabled", "true");
        paramCfg.setAttribute("disabled", "true");
        paramLength.setAttribute("disabled", "true");
        paramFps.setAttribute("disabled", "true");
        paramPrompt.setAttribute("disabled", "true");
        paramNegative.setAttribute("disabled", "true");

        // Hide previous outputs
        videoContainer.style.display = "none";
        outputVideo.querySelector("source").src = "";
        outputVideo.load();
        
        // Reset pipeline nodes UI
        resetNodesUI();
        
        const formData = new FormData();
        formData.append("sigma", paramSigma.value);
        formData.append("steps", paramSteps.value);
        formData.append("cfg", paramCfg.value);
        formData.append("num_frames", paramLength.value);
        formData.append("target_fps", paramFps.value);
        formData.append("prompt", paramPrompt.value.trim());
        formData.append("negative_prompt", paramNegative.value.trim());

        fetch("/api/run", {
            method: "POST",
            body: formData
        })
        .then(res => res.json())
        .then(data => {
            if (data.status === "started") {
                isPipelineRunning = true;
                appendLog("[SYSTEM] Pipeline orchestration launched.", "success-log");
                lastLogLength = 0;
                startPolling();
            } else {
                handleStopState();
                appendLog(`[ERROR] Failed to start pipeline: ${data.detail || 'Unknown error'}`, "error-log");
            }
        })
        .catch(err => {
            handleStopState();
            appendLog(`[ERROR] Launch request failed: ${err}`, "error-log");
        });
    });

    // Logging helpers
    function appendLog(text, className = "info-log") {
        if (!text) return;
        const line = document.createElement("div");
        line.className = `log-line ${className}`;
        line.textContent = text;
        consoleStream.appendChild(line);
        consoleStream.scrollTop = consoleStream.scrollHeight;
    }

    clearLogsBtn.addEventListener("click", () => {
        consoleStream.innerHTML = "";
    });

    // Polling System
    function startPolling() {
        if (pollInterval) clearInterval(pollInterval);
        pollInterval = setInterval(fetchPipelineStatus, 1500);
    }

    function stopPolling() {
        if (pollInterval) {
            clearInterval(pollInterval);
            pollInterval = null;
        }
    }

    function fetchPipelineStatus() {
        fetch("/api/status")
        .then(res => res.json())
        .then(data => {
            // Update logs
            if (data.logs && data.logs.length > lastLogLength) {
                const newLogs = data.logs.slice(lastLogLength);
                lastLogLength = data.logs.length;
                
                // Parse and append line by line
                const logLines = newLogs.split("\n");
                logLines.forEach(l => {
                    if (!l.trim()) return;
                    let cls = "info-log";
                    if (l.includes("ERROR") || l.includes("FATAL") || l.includes("failed")) cls = "error-log";
                    else if (l.includes("complete") || l.includes("COMPLETE") || l.includes("Success")) cls = "success-log";
                    else if (l.includes("[PIPELINE]") || l.includes("[SYSTEM]")) cls = "system-log";
                    appendLog(l, cls);
                });
            }

            // Update progress bar
            progressBar.style.width = `${data.progress}%`;
            progressPct.textContent = `${data.progress}%`;
            progressLabel.textContent = data.stage;

            // Highlight Nodes based on stage
            updateNodesUI(data.stage, data.sampler_step);

            // Check if finished
            if (!data.running && isPipelineRunning) {
                handleStopState();
                if (data.stage === "Complete" && data.video_available) {
                    appendLog("[SYSTEM] Render successful! Loading output video...", "success-log");
                    loadOutputVideo();
                } else if (data.error || data.stage === "Error") {
                    appendLog("[ERROR] Pipeline terminated with errors.", "error-log");
                }
            }
        })
        .catch(err => {
            console.error("Status polling failed:", err);
        });
    }

    function loadOutputVideo() {
        videoContainer.style.display = "block";
        const videoSource = outputVideo.querySelector("source");
        videoSource.src = "/output/final.mp4?t=" + new Date().getTime(); // Anti-cache query parameter
        outputVideo.load();
        outputVideo.play().catch(e => console.log("Video auto-play blocked: ", e));
        videoContainer.scrollIntoView({ behavior: 'smooth' });
    }

    function handleStopState() {
        isPipelineRunning = false;
        stopPolling();
        
        launchBtn.removeAttribute("disabled");
        launchBtn.classList.remove("running");
        launchBtn.querySelector(".btn-text").textContent = "LAUNCH QI TRANSMUTATION";
        
        // Re-enable sliders
        paramSigma.removeAttribute("disabled");
        paramSteps.removeAttribute("disabled");
        paramCfg.removeAttribute("disabled");
        paramLength.removeAttribute("disabled");
        paramFps.removeAttribute("disabled");
        paramPrompt.removeAttribute("disabled");
        paramNegative.removeAttribute("disabled");

        checkReadyState();
    }

    function resetNodesUI() {
        [nodeWham, nodeBlender, nodeControlnet, nodeComfyui].forEach(n => {
            n.className = "node-card";
            n.querySelector(".node-status").textContent = "Waiting";
        });
        [conn1, conn2, conn3].forEach(c => c.className = "connector");
    }

    function updateNodesUI(stage, samplerStep) {
        resetNodesUI();

        if (stage.includes("WHAM")) {
            nodeWham.className = "node-card active";
            nodeWham.querySelector(".node-status").textContent = "Extracting SMPL...";
        } 
        else if (stage.includes("Blender")) {
            nodeWham.className = "node-card completed";
            nodeWham.querySelector(".node-status").textContent = "Done";
            conn1.className = "connector active";
            
            nodeBlender.className = "node-card active";
            nodeBlender.querySelector(".node-status").textContent = "Smoothing & Floor Lock...";
        } 
        else if (stage.includes("ControlNet")) {
            nodeWham.className = "node-card completed";
            nodeWham.querySelector(".node-status").textContent = "Done";
            conn1.className = "connector active";
            
            nodeBlender.className = "node-card completed";
            nodeBlender.querySelector(".node-status").textContent = "Done";
            conn2.className = "connector active";
            
            nodeControlnet.className = "node-card active";
            nodeControlnet.querySelector(".node-status").textContent = "Mapping DensePose...";
        } 
        else if (stage.includes("Neural Render") || stage.includes("ComfyUI")) {
            nodeWham.className = "node-card completed";
            nodeWham.querySelector(".node-status").textContent = "Done";
            conn1.className = "connector active";
            
            nodeBlender.className = "node-card completed";
            nodeBlender.querySelector(".node-status").textContent = "Done";
            conn2.className = "connector active";
            
            nodeControlnet.className = "node-card completed";
            nodeControlnet.querySelector(".node-status").textContent = "Done";
            conn3.className = "connector active";
            
            nodeComfyui.className = "node-card active";
            nodeComfyui.querySelector(".node-status").textContent = samplerStep ? `Sampling ${samplerStep}` : "Inference Initiating...";
        } 
        else if (stage === "Complete") {
            nodeWham.className = "node-card completed";
            nodeWham.querySelector(".node-status").textContent = "Done";
            conn1.className = "connector active";
            
            nodeBlender.className = "node-card completed";
            nodeBlender.querySelector(".node-status").textContent = "Done";
            conn2.className = "connector active";
            
            nodeControlnet.className = "node-card completed";
            nodeControlnet.querySelector(".node-status").textContent = "Done";
            conn3.className = "connector active";
            
            nodeComfyui.className = "node-card completed";
            nodeComfyui.querySelector(".node-status").textContent = "Finished";
        }
        else if (stage === "Error") {
            // Highlight failed state if running terminated
            appendLog("[ERROR] An error occurred in the active pipeline block.", "error-log");
        }
    }
});
