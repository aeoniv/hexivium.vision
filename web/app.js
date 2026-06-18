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

    const paramMode = document.getElementById("param-mode");
    const valMode = document.getElementById("val-mode");
    const paramFps = document.getElementById("param-fps");
    const valFps = document.getElementById("val-fps");
    const paramPrompt = document.getElementById("param-prompt");
    const paramNegative = document.getElementById("param-negative");

    // Default creative direction (matches workflow_qi_pipeline.json node 10)
    const DEFAULT_PROMPT = "Cinematic 8k video, medium wide shot, a athletic practitioner performing sacred Tai Chi movements. Photorealistic bare skin texture with visible muscle definition, subtle skin pores, and natural body contours. Golden volumetric lighting cuts through a clean, minimalist studio background, catching the precise edge of the turning torso. Swirling bioluminescent particles of liquid light and auric currents flow smoothly along the pathways of the meridians and up the spine, pulsing with every slow kinetic transition. The energetic trails wrap seamlessly around the moving boundaries of the body, shifting from a warm glowing amber at the lower dantian base into an ethereal radiant white as it ascends the spinal column. Flowing motion, highly detailed anatomy, hyper-realistic physics, clean framing, shallow depth of field, filmic quality.";
    const DEFAULT_NEGATIVE = "text, watermark, logo, deformed limbs, floating joints, extra fingers, clothing, underwear, fabrics, swimming trunks, rubbery skin, sudden morphing, rapid camera cuts, motion blur artifacts, flat lighting, background noise, low resolution, plastic texture, cartoon, 3D render artifact.";
    if (paramPrompt && !paramPrompt.value) paramPrompt.value = DEFAULT_PROMPT;
    if (paramNegative && !paramNegative.value) paramNegative.value = DEFAULT_NEGATIVE;

    const avatarPrompt = document.getElementById("avatar-prompt");
    const generateAvatarBtn = document.getElementById("generate-avatar-btn");
    const avatarRefInput = document.getElementById("avatar-ref-input");
    const avatarRefName = document.getElementById("avatar-ref-name");
    const avatarPreview = document.getElementById("avatar-preview");
    const avatarPreviewImg = document.getElementById("avatar-preview-img");

    // ── Parametric Avatar Composer (6-line hexagram token matrix) ───────────
    const AVATAR_NEGATIVE = "corridor, background scenery, room, walls, bokeh lights, depth of field, outdoor, indoor, cropped feet, cut off shoes, out of frame legs, vertical cropping at ankles, missing toes, truncated lower limbs, blurry hands, double faces, asymmetric eyes, text overlays, signatures, logos, watermarks, distorted joints, explicit nudity, vulgarity, rough sketching, 2D flat style, bad anatomy, deformed anatomy, low resolution background";

    const COMPOSER = [
        { key: "shot", label: "Shot", opts: [
            "a full-length full-body", "a full-length wide-angle", "an ortho-view full-body",
            "an ultra-sharp full-length asset", "a high-resolution full-body", "a head-to-toe studio asset" ] },
        { key: "frame", label: "Frame", opts: [
            "female", "male", "androgynous", "femboy", "tomboy", "fluid neutral" ] },
        { key: "heritage", label: "Heritage", opts: [
            "American Indian / Alaska Native, deep copper skin tones and high cheekbones",
            "East Asian, smooth porcelain skin tones",
            "Black / African American, rich ebony skin tones",
            "Hispanic / Latino, golden-bronze sun-kissed skin tones",
            "Middle Eastern / North African, warm olive complexion",
            "White, clear alabaster skin tones" ] },
        { key: "build", label: "Build", opts: [
            "a slender, lithe model build", "a toned athletic build", "a strong muscular build",
            "a balanced symmetric build", "a lean dancer's build", "a compact, sturdy build" ] },
        { key: "attire", label: "Attire", opts: [
            "a sleek matte-black athletic tracking set with black trainers",
            "minimalist techwear — a zip jacket and tapered cargo trousers with low boots",
            "a tailored modern suit with clean lines and dress shoes",
            "relaxed streetwear — an oversized hoodie and joggers with sneakers",
            "a fitted performance bodysuit with a structured overlay and athletic shoes",
            "a flowing traditional-inspired robe set with soft sandals" ] },
        { key: "aspect", label: "Aspect", opts: [
            "striking blue eyes, clean high-arch eyebrows and a calm neutral expression",
            "expressive purple eyes, soft straight eyebrows and a confident subtle smirk",
            "sharp jade-green eyes, angular eyebrows and a focused, composed look",
            "warm liquid-gold eyes, sleek minimalist eyebrows and a serene gaze",
            "electric-blue almond eyes, split-cut eyebrows and a poised expression",
            "soft amber eyes, natural eyebrows and a gentle, approachable smile" ] },
    ];
    const composerState = {};

    function cap(t) { return t.charAt(0).toUpperCase() + t.slice(1); }
    function shortLabel(key, o) {
        if (key === "heritage") return o.split(",")[0];
        if (key === "attire") return o.split("—")[0].trim();
        if (key === "aspect") return o.split(",")[0];
        if (key === "build") return cap(o.replace(/^a /, "").replace(" build", ""));
        return cap(o);
    }
    function buildAvatarPrompt() {
        const s = composerState;
        const heritageName = s.heritage.split(",")[0];
        const heritageDesc = s.heritage.split(",").slice(1).join(",").trim();
        return `A crisp, pristine ${s.shot} stylized character model-sheet render featuring a ${heritageName} ${s.frame} avatar — ${heritageDesc} — standing in a precise, centered anatomical T-pose facing the camera from head to toe with no cropping. ${cap(s.aspect)}. Hair styled in a sleek jet-black ponytail with sharp straight-cut bangs. Physique: ${s.build}, perfectly grounded on the floor plane. Wearing ${s.attire}. Completely isolated against a solid, flat, uniform studio-white background with zero environment. Flat, even digital lighting with a clean physics-based contact shadow anchoring the figure to the floor plane. Flawless high-fidelity 8k CG render with clean line work.`;
    }
    (function initComposer() {
        const linesEl = document.getElementById("hex-lines");
        const sealEl = document.getElementById("hex-seal");
        if (!linesEl || !avatarPrompt) return;
        // Hexagram seal: 6 stacked lines, first category = bottom line (I Ching order).
        COMPOSER.forEach(() => { const i = document.createElement("i"); i.className = "seal-line yin"; sealEl.prepend(i); });
        COMPOSER.forEach((cat, idx) => {
            composerState[cat.key] = cat.opts[0];
            const row = document.createElement("div"); row.className = "hex-line";
            const glyph = document.createElement("span"); glyph.className = "hex-glyph yin";
            const ctrl = document.createElement("div"); ctrl.className = "hex-control";
            const lab = document.createElement("label"); lab.textContent = cat.label;
            const sel = document.createElement("select");
            cat.opts.forEach((o) => { const op = document.createElement("option"); op.value = o; op.textContent = shortLabel(cat.key, o); sel.appendChild(op); });
            sel.addEventListener("change", () => {
                composerState[cat.key] = sel.value;
                const yang = sel.selectedIndex !== 0;
                glyph.className = "hex-glyph " + (yang ? "yang" : "yin");
                sealEl.children[COMPOSER.length - 1 - idx].className = "seal-line " + (yang ? "yang" : "yin");
                avatarPrompt.value = buildAvatarPrompt();
            });
            ctrl.appendChild(lab); ctrl.appendChild(sel);
            row.appendChild(glyph); row.appendChild(ctrl);
            linesEl.appendChild(row);
        });
        avatarPrompt.value = buildAvatarPrompt();
    })();

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

    // Dynamic value display
    paramFps.addEventListener("change", (e) => valFps.textContent = `${e.target.value} fps`);
    paramMode.addEventListener("change", (e) => {
        valMode.textContent = e.target.value === "funcontrol" ? "Stylized" : "Faithful";
    });

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
        
        // Disable controls
        paramMode.setAttribute("disabled", "true");
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
        // Animate quality is fixed server-side (6-step distill, cfg 1, 720p, whole clip);
        // these are sent only to satisfy the API and are ignored/forced for animate mode.
        formData.append("sigma", "2.0");
        formData.append("steps", "6");
        formData.append("cfg", "1.0");
        formData.append("num_frames", "81");
        formData.append("target_fps", paramFps.value);
        formData.append("mode", paramMode.value);
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

    // ── Generate Avatar (SDXL text-to-image) ────────────────────────────────
    let avatarPoll = null;
    if (avatarRefInput) {
        avatarRefInput.addEventListener("change", (e) => {
            const f = e.target.files[0];
            if (avatarRefName) avatarRefName.textContent = f
                ? `Reference: ${f.name} — will generate a variation of it (img2img).`
                : "No reference — generating from text.";
        });
    }

    generateAvatarBtn.addEventListener("click", () => {
        const btnText = generateAvatarBtn.querySelector(".btn-text");
        generateAvatarBtn.setAttribute("disabled", "true");
        btnText.textContent = "GENERATING AVATAR...";
        appendLog("[SYSTEM] Generating reference avatar (SDXL)...", "system-log");

        const fd = new FormData();
        fd.append("prompt", avatarPrompt.value.trim());
        fd.append("negative_prompt", AVATAR_NEGATIVE);
        if (avatarRefInput && avatarRefInput.files.length > 0) {
            fd.append("init_image", avatarRefInput.files[0]);  // → SDXL img2img
        }

        fetch("/api/generate-avatar", { method: "POST", body: fd })
            .then(res => res.json())
            .then(data => {
                if (data.status !== "started") {
                    throw new Error(data.detail || "could not start");
                }
                avatarPoll = setInterval(() => {
                    fetch("/api/avatar-status").then(r => r.json()).then(s => {
                        if (s.running) return;
                        clearInterval(avatarPoll);
                        generateAvatarBtn.removeAttribute("disabled");
                        btnText.textContent = "GENERATE AVATAR";
                        if (s.ready) {
                            avatarPreviewImg.src = "/input/reference_image.png?t=" + Date.now();
                            avatarPreview.style.display = "block";
                            isImageUploaded = true;
                            imageFileName.textContent = "Generated avatar (ready)";
                            appendLog("[SUCCESS] Avatar generated — set as reference.", "success-log");
                            checkReadyState();
                        } else {
                            appendLog(`[ERROR] Avatar generation failed: ${s.error || "see logs"}`, "error-log");
                        }
                    });
                }, 2500);
            })
            .catch(err => {
                generateAvatarBtn.removeAttribute("disabled");
                btnText.textContent = "GENERATE AVATAR";
                appendLog(`[ERROR] Avatar generation request failed: ${err}`, "error-log");
            });
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

            // Highlight Nodes based on progress
            updateNodesUI(data.progress, data.sampler_step, data.stage);

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
        
        // Re-enable controls
        paramMode.removeAttribute("disabled");
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

    // Drive the 4-node animate flow off the overall progress %, which maps to the
    // real stages: extract→45, model-load+pose 45-65, sampler 65-98, RIFE/output 98-100.
    function updateNodesUI(progress, samplerStep, stage) {
        resetNodesUI();
        if (stage === "Error") {
            appendLog("[ERROR] An error occurred in the active pipeline block.", "error-log");
            return;
        }
        const p = Number(progress) || 0;
        const done = (node, conn) => {
            node.className = "node-card completed";
            node.querySelector(".node-status").textContent = "Done";
            if (conn) conn.className = "connector active";
        };
        const active = (node, status) => {
            node.className = "node-card active";
            node.querySelector(".node-status").textContent = status;
        };
        const complete = p >= 100 || stage === "Complete";

        // 1 — Extract Frames
        if (p >= 45) done(nodeWham, conn1); else if (p > 0) active(nodeWham, "Extracting driving frames…");
        // 2 — Load model & detect pose/face
        if (p >= 65) done(nodeBlender, conn2); else if (p >= 45) active(nodeBlender, "Loading model & detecting pose…");
        // 3 — Wan-Animate render (sampler)
        if (p >= 98) done(nodeControlnet, conn3); else if (p >= 65) active(nodeControlnet, samplerStep ? `Sampling ${samplerStep}` : "Rendering…");
        // 4 — RIFE interpolation + output
        if (complete) { nodeComfyui.className = "node-card completed"; nodeComfyui.querySelector(".node-status").textContent = "Finished"; }
        else if (p >= 98) active(nodeComfyui, "Interpolating & encoding…");
    }
});
