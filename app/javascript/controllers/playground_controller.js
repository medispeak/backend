import { Controller } from "@hotwired/stimulus"

// The template playground: run this template against real input, two ways.
//
// AUDIO. Voice-activity detection (Silero, via the vendored @ricky0123/vad-web)
// cuts the mic stream into whole utterances. Each utterance is POSTed to
// /audio/segments as its own WAV, which is what that endpoint wants — an
// independently decodable part it can transcribe on arrival. That is what buys
// the transcript that grows while the user is still talking; the sibling
// /audio/chunks endpoint byte-concatenates its parts and could not decode them.
//
// DOCUMENT. A lab report (PDF, or a photo per page) is POSTed to /documents,
// one file per request and strictly in order — attachment id is upload order is
// reading order, and the server OCRs them as one document in that order. The
// server counts pages, which the browser cannot, so it owns the real ceilings.
//
// The two differ only in how the transcript comes to exist. Commit, polling,
// structuring, metering and the rendered result are one shared path from there,
// which is the point of running both from this page.
//
// Everything after session creation talks to the public /api/v2 with a
// short-lived `mss_` token, so this page exercises the same API a customer
// integrates against rather than a private shortcut.

const VAD_SAMPLE_RATE = 16000

// Sarvam's REST ASR rejects audio over ~30s, so an utterance that runs long is
// hard-split under the ceiling rather than sent whole and 400'd.
const MAX_SEGMENT_SECONDS = 20

// Polling is a shared budget with segment uploads: Rack::Attack throttles the
// whole account at 120 rpm. Slow while recording (the transcript grows in
// human time anyway), fast once committed (the tail is only a few seconds).
const POLL_MS_RECORDING = 2000
const POLL_MS_PROCESSING = 750
const POLL_MAX_MS = 5 * 60 * 1000

const FIELD_FILL_DELAY_MS = 500

// How long to record hearing nothing before saying so. Long enough to cover a
// slow start, short enough that a muted microphone is caught in seconds rather
// than discovered at commit.
const SILENCE_HINT_MS = 8000
const TERMINAL_STATUSES = new Set(["completed", "partial", "failed"])

export default class extends Controller {
  static targets = [
    "record", "orbIcon", "bars", "statusLabel", "statusHint", "steps", "timer",
    "pause", "error", "errorMessage", "retry", "transcriptCard",
    "transcriptBadge", "transcript", "fields", "result",
    "modeAudio", "modeDocument", "audioControls", "documentControls",
    "pick", "fileInput", "extract", "fileList", "stepZero", "transcriptTitle"
  ]

  static values = {
    createSessionUrl: String,
    tokenUrlTemplate: String,
    resultUrl: String,
    apiBase: String,
    vadBase: String,
    ortBase: String,
    maxFileBytes: Number,
    maxTotalBytes: Number,
    documentTypes: Array
  }

  connect() {
    this.state = "idle"
    this.modality = "audio"
    this.files = []
    this.uploaded = false
    this.seq = 0
    this.inflight = 0
    this.session = null
    this.token = null
    this.stream = null
    this.vad = null
    this.audioContext = null
    this.analyser = null
    this.rafId = null
    this.timerId = null
    this.pollId = null
    this.vadLoading = null
    this.startedAt = null
    this.pausedMs = 0
    this.pausedAt = null
  }

  // Stimulus tears the controller down on navigation; without this the mic
  // stays live and the AudioContext leaks.
  disconnect() {
    this.teardownCapture()
    this.stopPolling()
    if (this.timerId) clearInterval(this.timerId)
  }

  // ── controls ─────────────────────────────────────────────────────────────

  toggle() {
    if (this.state === "idle" || this.state === "done" || this.state === "failed") {
      this.start()
    } else if (this.state === "recording" || this.state === "paused") {
      this.finish()
    }
  }

  togglePause() {
    if (this.state === "recording") {
      this.vad?.pause()
      this.pausedAt = Date.now()
      this.setState("paused")
    } else if (this.state === "paused") {
      this.pausedMs += Date.now() - this.pausedAt
      this.pausedAt = null
      this.vad?.start()
      this.setState("recording")
    }
  }

  // ── source mode ──────────────────────────────────────────────────────────

  useAudio() { this.setModality("audio") }
  useDocument() { this.setModality("document") }

  // Switching mid-run would orphan a session that is already being billed, so
  // the switch is inert once something is under way; setState re-disables the
  // buttons for the same reason.
  setModality(modality) {
    if (this.modality === modality) return
    if (["preparing", "recording", "paused", "processing"].includes(this.state)) return

    this.modality = modality
    this.session = null
    this.token = null
    this.files = []
    this.fileInputTarget.value = ""

    const doc = modality === "document"
    this.modeAudioTarget.className = `pg-mode${doc ? "" : " pg-mode-on"}`
    this.modeDocumentTarget.className = `pg-mode${doc ? " pg-mode-on" : ""}`
    this.modeAudioTarget.setAttribute("aria-pressed", String(!doc))
    this.modeDocumentTarget.setAttribute("aria-pressed", String(doc))

    this.recordTarget.classList.toggle("hidden", doc)
    this.pickTarget.classList.toggle("hidden", !doc)
    this.audioControlsTarget.classList.toggle("hidden", doc)
    this.documentControlsTarget.classList.toggle("flex", doc)
    this.documentControlsTarget.classList.toggle("hidden", !doc)

    this.transcriptTitleTarget.textContent = doc ? "Extracted text" : "Transcript"
    this.stepZeroTarget.textContent = doc ? "Reading document" : "Transcribing"

    this.hideError()
    this.resetFields()
    this.renderFileList()
    this.setState("idle")
  }

  // ── documents ────────────────────────────────────────────────────────────

  chooseFiles() {
    if (this.state === "processing") return
    this.fileInputTarget.click()
  }

  // The sr-only input is still keyboard-reachable, so this can fire mid-run
  // even though the orb refuses to open the dialog then. Swapping the file list
  // under a running upload loop would arm Extract for a second, concurrent
  // session — ignore it, the way every other control is inert while busy.
  filesChosen() {
    if (this.state === "processing") return
    this.hideError()
    this.files = Array.from(this.fileInputTarget.files || [])
    this.renderFileList()
  }

  // Local pre-flight only. The server re-checks every one of these on arrival
  // and additionally counts pages, so this exists to spend a message instead of
  // an upload — never to decide what is allowed.
  rejectionFor(files) {
    const types = this.documentTypesValue || []
    const bad = files.find((file) => file.type && types.length && !types.includes(file.type))
    if (bad) return `${bad.name} is not a PDF or an image.`

    const tooBig = files.find((file) => file.size > this.maxFileBytesValue)
    if (tooBig) return `${tooBig.name} is larger than ${this.formatBytes(this.maxFileBytesValue)}.`

    const total = files.reduce((sum, file) => sum + file.size, 0)
    if (total > this.maxTotalBytesValue) {
      return `Those files total ${this.formatBytes(total)}, over the ${this.formatBytes(this.maxTotalBytesValue)} limit.`
    }
    return null
  }

  renderFileList() {
    const list = this.fileListTarget
    list.innerHTML = ""
    const rejection = this.files.length ? this.rejectionFor(this.files) : null

    for (const file of this.files) {
      const row = document.createElement("li")
      row.className = "flex items-center justify-between gap-3 rounded-lg border border-gray-200 px-3 py-2"
      const name = document.createElement("span")
      name.className = "min-w-0 flex-1 truncate text-sm text-gray-700"
      name.textContent = file.name
      const size = document.createElement("span")
      size.className = "num shrink-0 text-xs tabular-nums text-gray-400"
      size.textContent = this.formatBytes(file.size)
      row.append(name, size)
      list.append(row)
    }

    list.classList.toggle("hidden", this.files.length === 0)
    this.extractTarget.disabled = this.state === "processing" || this.files.length === 0 || Boolean(rejection)
    if (rejection) this.showError(rejection)

    if (this.files.length && !rejection && this.state === "idle") {
      this.statusHintTarget.textContent =
        `${this.files.length} ${this.files.length === 1 ? "file" : "files"} ready. Press Extract.`
    }
  }

  async extract() {
    // A second Extract while the first is uploading would open a second
    // session against the same files; the button is disabled while busy, but
    // the guard belongs here too, where the session is actually created.
    if (this.state === "processing") return
    if (!this.files.length || this.rejectionFor(this.files)) return

    this.hideError()
    this.resetFields()
    this.setState("processing")
    // Cleared until every file has landed, so retry() knows whether the session
    // on the server holds the complete document or a half-uploaded one.
    this.uploaded = false

    try {
      const session = await this.createSession()
      this.session = session.session_id
      this.token = session.token

      // Strictly sequential: attachment id is upload order is the order the
      // report is transcribed in, so racing these would shuffle the pages of a
      // photographed report. The per-request row lock makes concurrency safe,
      // not correct.
      for (const file of this.files) {
        const body = new FormData()
        body.append("document", file, file.name)
        await this.apiFetch(`/scribe_sessions/${this.session}/documents`, { method: "POST", body })
      }
      // Set BEFORE the commit, not after it: once every page is stored the
      // session is complete, and if the commit call itself fails — or the
      // server accepts it and the response is lost — the honest retry is to
      // commit THAT session again, not to upload the whole report to a new one
      // (which, when the first commit had in fact landed, bills two OCR runs).
      this.uploaded = true

      await this.apiFetch(`/scribe_sessions/${this.session}/commit`, { method: "POST" })
      this.startPolling(POLL_MS_PROCESSING)
    } catch (err) {
      this.fail(err.message, { retryable: true })
    }
  }

  formatBytes(bytes) {
    if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
    if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`
    return `${bytes} B`
  }

  // Re-commit. For audio, a commit fails as a unit when any segment has not
  // settled and re-committing retries exactly those. For a document session the
  // uploads are already stored, so this re-runs OCR against them — which is a
  // fresh provider call and is billed as one.
  //
  // EXCEPT when the upload loop itself broke. The loop aborts on the first
  // failure, so page 2 of 3 dropping leaves ONE page on the server — and
  // commit's gate only requires that some document is attached. Re-committing
  // there would OCR a third of a lab report, structure it, and finish green: a
  // partial clinical document presented as complete, which is precisely what
  // the server-side truncation guard exists to prevent. Start over instead, on
  // a fresh session, so every page is uploaded again.
  async retry() {
    if (this.modality === "document" && !this.uploaded) {
      this.session = null
      this.token = null
      return this.extract()
    }

    this.hideError()
    this.setState("processing")
    try {
      await this.apiFetch(`/scribe_sessions/${this.session}/commit`, { method: "POST" })
      this.startPolling(POLL_MS_PROCESSING)
    } catch (err) {
      this.fail(err.message, { retryable: true })
    }
  }

  // ── run lifecycle ────────────────────────────────────────────────────────

  async start() {
    this.hideError()
    this.resetFields()
    this.seq = 0
    this.pausedMs = 0
    this.setState("preparing")

    try {
      // The VAD bundle is ~12MB of wasm and the session create can 402 on a
      // usage limit. Run both now, in parallel, so a refusal arrives before we
      // ever prompt for the microphone.
      const [session] = await Promise.all([this.createSession(), this.loadVad()])
      this.session = session.session_id
      this.token = session.token

      this.stream = await navigator.mediaDevices.getUserMedia({
        audio: { channelCount: 1, echoCancellation: true, autoGainControl: true, noiseSuppression: true }
      })

      this.startMeter(this.stream)

      this.vad = await window.vad.MicVAD.new({
        stream: this.stream,
        model: "v5",
        baseAssetPath: this.vadBaseValue,
        onnxWASMBasePath: this.ortBaseValue,
        // Multi-threaded onnxruntime needs SharedArrayBuffer, which would
        // require COOP/COEP cross-origin isolation across the whole app.
        ortConfig: (ort) => {
          ort.env.wasm.numThreads = 1
          ort.env.wasm.simd = true
        },
        onSpeechEnd: (audio) => this.uploadUtterance(audio)
      })

      this.vad.start()
      this.startedAt = Date.now()
      this.startTimer()
      this.setState("recording")
      this.startPolling(POLL_MS_RECORDING)
    } catch (err) {
      this.teardownCapture()
      this.fail(this.describeStartError(err))
    }
  }

  async finish() {
    this.setState("processing")
    this.stopTimer()
    this.teardownCapture()

    try {
      // Segments already in flight must land before commit, or the session
      // finalizes against an incomplete transcript.
      await this.drainUploads()

      // Nothing was ever detected as speech, so there is nothing to commit.
      // Committing anyway spends a round-trip to be told "No audio uploaded for
      // this session", which reads like a server fault when it is almost always
      // a silent microphone. Say the useful thing instead.
      if (this.seq === 0) {
        this.fail(
          "No speech was detected, so there was nothing to transcribe. Check that the right " +
          "microphone is selected and unmuted — then press record and speak normally.",
          { retryable: false }
        )
        return
      }

      await this.apiFetch(`/scribe_sessions/${this.session}/commit`, { method: "POST" })
      this.startPolling(POLL_MS_PROCESSING)
    } catch (err) {
      this.fail(err.message, { retryable: true })
    }
  }

  // ── capture ──────────────────────────────────────────────────────────────

  async uploadUtterance(audio) {
    for (const slice of this.capSegments(audio)) {
      const seq = this.seq++
      const body = new FormData()
      body.append("seq", String(seq))
      // 16-bit PCM (format 1) rather than the library's 32-bit float default:
      // half the bytes over the wire, and universally decodable.
      body.append(
        "segment",
        new Blob([window.vad.utils.encodeWAV(slice, 1, VAD_SAMPLE_RATE, 1, 16)], { type: "audio/wav" }),
        `${seq}.wav`
      )

      this.inflight++
      this.renderCaptureCount()
      try {
        await this.apiFetch(`/scribe_sessions/${this.session}/audio/segments`, { method: "POST", body })
      } catch (err) {
        // One lost utterance should not kill a live recording — but commit will
        // refuse a session whose segments never settled, so say so now.
        this.showError(`A piece of audio failed to upload (${err.message}). The transcript may be incomplete.`)
      } finally {
        this.inflight--
      }
    }
  }

  * capSegments(samples) {
    const max = Math.floor(MAX_SEGMENT_SECONDS * VAD_SAMPLE_RATE)
    if (samples.length <= max) {
      yield samples
      return
    }
    for (let offset = 0; offset < samples.length; offset += max) {
      yield samples.subarray(offset, Math.min(offset + max, samples.length))
    }
  }

  async drainUploads() {
    const deadline = Date.now() + 30000
    while (this.inflight > 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
  }

  startMeter(stream) {
    this.audioContext = new AudioContext()
    this.analyser = this.audioContext.createAnalyser()
    this.analyser.fftSize = 256
    this.analyser.smoothingTimeConstant = 0.75
    this.audioContext.createMediaStreamSource(stream).connect(this.analyser)

    const data = new Uint8Array(this.analyser.frequencyBinCount)
    const bars = Array.from(this.barsTarget.querySelectorAll("i"))
    // Five bins spread across speech frequencies, so the bars track a voice
    // rather than all moving as one.
    const bins = [250, 500, 900, 1600, 2800].map((hz) =>
      Math.min(data.length - 1, Math.round((hz / (this.audioContext.sampleRate / 2)) * data.length))
    )

    const draw = () => {
      this.analyser.getByteFrequencyData(data)
      bars.forEach((bar, i) => {
        const level = this.state === "paused" ? 0 : data[bins[i]] / 255
        bar.style.transform = `scaleY(${Math.max(0.15, Math.min(1, level * 1.8))})`
      })
      this.rafId = requestAnimationFrame(draw)
    }
    draw()
  }

  teardownCapture() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    this.rafId = null
    this.vad?.destroy?.()
    this.vad = null
    this.stream?.getTracks().forEach((track) => track.stop())
    this.stream = null
    if (this.audioContext && this.audioContext.state !== "closed") this.audioContext.close()
    this.audioContext = null
    this.analyser = null
  }

  // ── polling ──────────────────────────────────────────────────────────────

  startPolling(interval) {
    this.stopPolling()
    this.pollDeadline = Date.now() + POLL_MAX_MS
    const tick = async () => {
      try {
        const payload = await this.apiFetch(`/scribe_sessions/${this.session}`)
        this.render(payload)
        if (TERMINAL_STATUSES.has(payload.status)) {
          this.stopPolling()
          await this.complete(payload)
          return
        }
      } catch (err) {
        this.stopPolling()
        this.fail(err.message, { retryable: true })
        return
      }
      if (Date.now() > this.pollDeadline) {
        this.stopPolling()
        this.fail("This run took longer than expected. It may still finish — check your consultations.")
        return
      }
      this.pollId = setTimeout(tick, interval)
    }
    this.pollId = setTimeout(tick, interval)
  }

  stopPolling() {
    if (this.pollId) clearTimeout(this.pollId)
    this.pollId = null
  }

  render(payload) {
    const text = payload.transcript?.text
    if (text) {
      this.transcriptCardTarget.classList.remove("hidden")
      this.transcriptTarget.textContent = text
    }

    // The step is derived from what the API has actually produced, never from a
    // timer: no transcript yet means ASR is still running; a transcript with
    // non-terminal outputs means structuring is.
    if (this.state === "processing") {
      const outputsDone = (payload.outputs || []).length > 0 &&
        (payload.outputs || []).every((output) => output.status !== "pending")
      this.setStep(outputsDone ? 2 : text ? 1 : 0)
    }
  }

  async complete(payload) {
    // "auto" is the no-hint sentinel, not a detected language — a document
    // transcript carries the session's hint verbatim because OCR detects
    // nothing, so it would otherwise surface as a badge reading "auto".
    const language = payload.transcript?.language
    this.transcriptBadgeTarget.textContent = language && language !== "auto" ? language : "Done"
    this.transcriptBadgeTarget.className = "badge badge-neutral"

    await this.fillFields(payload)

    // Swap the live rows for the authoritative server render, which shares the
    // consultation view's partial — so a playground result and a real
    // consultation can never drift apart in how they read.
    try {
      const response = await fetch(`${this.resultUrlValue}?session_id=${encodeURIComponent(this.session)}`, {
        headers: { Accept: "text/html" }
      })
      if (response.ok) {
        this.resultTarget.innerHTML = await response.text()
        this.resultTarget.classList.remove("hidden")
        this.fieldsTarget.classList.add("hidden")
      }
    } catch { /* the filled rows above are already a usable result */ }

    if (payload.status === "failed") {
      this.setState("failed")
      this.showError(this.failureMessage(payload), { retryable: true })
    } else {
      this.setState("done")
    }
  }

  // Fields land one at a time rather than all at once: the stagger is what
  // makes it read as the form being filled in, which is the thing being
  // demonstrated.
  async fillFields(payload) {
    const values = {}
    for (const output of payload.outputs || []) {
      if (output.type === "form" && output.result) Object.assign(values, output.result)
    }

    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    for (const [key, value] of Object.entries(values)) {
      const field = this.fieldsTarget.querySelector(`[data-field-key="${CSS.escape(key)}"]`)
      if (!field) continue

      const slot = field.querySelector(".pg-field-value")
      slot.textContent = this.formatValue(value)
      slot.classList.toggle("text-gray-300", this.isEmpty(value))
      field.classList.add("pg-field-filled")

      if (!reduced) {
        field.scrollIntoView({ behavior: "smooth", block: "nearest" })
        await new Promise((resolve) => setTimeout(resolve, FIELD_FILL_DELAY_MS))
      }
    }
  }

  resetFields() {
    this.resultTarget.classList.add("hidden")
    this.resultTarget.innerHTML = ""
    this.fieldsTarget.classList.remove("hidden")
    this.fieldsTarget.querySelectorAll(".pg-field").forEach((field) => {
      field.classList.remove("pg-field-filled")
      const slot = field.querySelector(".pg-field-value")
      slot.textContent = "—"
      slot.classList.add("text-gray-300")
    })
    this.transcriptTarget.textContent = ""
    this.transcriptCardTarget.classList.add("hidden")
    this.transcriptBadgeTarget.textContent = this.modality === "document" ? "Reading" : "Listening"
    this.transcriptBadgeTarget.className = "badge badge-progress"
  }

  isEmpty(value) {
    return value === null || value === undefined || value === "" ||
      (Array.isArray(value) && value.length === 0)
  }

  formatValue(value) {
    if (value === true) return "Yes"
    if (value === false) return "No"
    if (this.isEmpty(value)) return "—"
    if (Array.isArray(value)) return value.join(", ")
    if (typeof value === "object") return JSON.stringify(value)
    return String(value)
  }

  failureMessage(payload) {
    const fromOutputs = (payload.outputs || [])
      .flatMap((output) => output.errors || [])
      .map((error) => (typeof error === "string" ? error : error.message))
      .filter(Boolean)
    if (fromOutputs[0]) return fromOutputs[0]
    return this.modality === "document"
      ? "This run failed. Retry to read the same document again."
      : "This run failed. Retry to try the same audio again."
  }

  // ── transport ────────────────────────────────────────────────────────────

  async createSession() {
    const response = await fetch(this.createSessionUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify({ modality: this.modality })
    })
    const payload = await response.json().catch(() => ({}))
    if (!response.ok) throw new Error(payload.error?.message || "Could not start a session.")
    return payload
  }

  // A `mss_` token lives 15 minutes and an expired one is indistinguishable
  // from an invalid one — both are a bodyless 401 — so the token is re-minted
  // on the first 401 rather than predicted.
  async apiFetch(path, options = {}, retried = false) {
    const response = await fetch(`${this.apiBaseValue}${path}`, {
      ...options,
      headers: { ...(options.headers || {}), Authorization: `Bearer ${this.token}` }
    })

    if (response.status === 401 && !retried) {
      this.token = await this.remintToken()
      return this.apiFetch(path, options, true)
    }

    if (!response.ok) {
      // 401 carries no body at all, so this must not assume JSON.
      const payload = await response.json().catch(() => ({}))
      throw new Error(payload.error?.message || `Request failed (${response.status})`)
    }

    return response.status === 204 ? {} : response.json()
  }

  async remintToken() {
    const url = this.tokenUrlTemplateValue.replace("SESSION_ID", encodeURIComponent(this.session))
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      }
    })
    if (!response.ok) throw new Error("Your session expired. Start a new recording.")
    return (await response.json()).token
  }

  // The VAD is a UMD bundle reading a global `ort`, so onnxruntime must be
  // evaluated first. Both are injected as same-origin <script src> rather than
  // inlined, which keeps them inside `script_src :self`.
  loadVad() {
    if (window.vad) return Promise.resolve()
    this.vadLoading ||= (async () => {
      await this.loadScript(`${this.ortBaseValue}ort.wasm.min.js`)
      window.ort.env.wasm.numThreads = 1
      window.ort.env.wasm.wasmPaths = this.ortBaseValue
      await this.loadScript(`${this.vadBaseValue}vad.bundle.min.js`)
    })()
    return this.vadLoading
  }

  loadScript(src) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script")
      script.src = src
      script.onload = resolve
      script.onerror = () => reject(new Error(`Could not load ${src}`))
      document.head.appendChild(script)
    })
  }

  // ── presentation ─────────────────────────────────────────────────────────

  setState(state) {
    this.state = state
    const document_ = this.modality === "document"

    const shared = {
      done: ["Done", "This ran through the same pipeline your integration will."],
      failed: ["Something went wrong", "Nothing was charged for a run that failed to transcribe."]
    }
    const copy = (document_ ? {
      ...shared,
      processing: ["Working on it", "Reading the document, then filling the form."],
      idle: ["Ready when you are", "Choose a lab report — a PDF, or a photo per page."]
    } : {
      ...shared,
      preparing: ["Getting ready", "Loading the recogniser and asking for your microphone."],
      recording: ["Listening", "Speak naturally. Pauses are fine — it splits on them."],
      paused: ["Paused", "Resume when you are ready."],
      processing: ["Working on it", "Transcribing what you said, then filling the form."],
      idle: ["Ready when you are", "Press record and describe a consultation out loud."]
    })[state] || ["", ""]

    this.statusLabelTarget.textContent = copy[0]
    this.statusHintTarget.textContent = copy[1]
    // Reset: renderCaptureCount may have left the hint in its amber
    // nothing-heard-yet styling.
    this.statusHintTarget.className = "mt-0.5 text-sm text-gray-500"

    const recording = state === "recording" || state === "paused"
    const busy = state === "processing"
    this.recordTarget.className =
      `pg-orb pg-orb-${busy ? "busy" : recording ? "recording" : "idle"}${document_ ? " hidden" : ""}`
    this.recordTarget.disabled = state === "preparing" || busy
    this.recordTarget.setAttribute("aria-label", recording ? "Stop recording" : "Start recording")
    this.pickTarget.className = `pg-orb pg-orb-${busy ? "busy" : "idle"}${document_ ? "" : " hidden"}`
    this.pickTarget.disabled = busy
    // The input itself too: it is sr-only, not display:none, so it is still in
    // the tab order when the orb that fronts it is disabled.
    this.fileInputTarget.disabled = busy
    this.extractTarget.disabled = busy || this.files.length === 0 || Boolean(this.rejectionFor(this.files))

    // A mid-run switch would orphan a session that is already being billed.
    this.modeAudioTarget.disabled = busy || state === "preparing" || recording
    this.modeDocumentTarget.disabled = this.modeAudioTarget.disabled

    this.barsTarget.classList.toggle("hidden", !recording)
    this.timerTarget.classList.toggle("hidden", !recording)
    this.pauseTarget.classList.toggle("hidden", !recording)
    this.pauseTarget.textContent = state === "paused" ? "Resume" : "Pause"
    this.stepsTarget.classList.toggle("hidden", !busy)
    if (busy) {
      this.setStep(0)
      // The mic is closed by now, so "Listening" would be a lie.
      this.transcriptBadgeTarget.textContent = "In progress"
    }
  }

  setStep(index) {
    this.stepsTarget.querySelectorAll("[data-step]").forEach((badge) => {
      const step = Number(badge.dataset.step)
      badge.className = `badge ${step < index ? "badge-success" : step === index ? "badge-progress" : "badge-neutral"}`
    })
  }

  startTimer() {
    this.timerId = setInterval(() => {
      if (this.state === "paused") return
      const elapsed = Math.floor((Date.now() - this.startedAt - this.pausedMs) / 1000)
      this.timerTarget.textContent = `${Math.floor(elapsed / 60)}:${String(elapsed % 60).padStart(2, "0")}`
      this.renderCaptureCount()
    }, 250)
  }

  // Speech detection is the one part of this the user cannot see. Left unsaid, a
  // muted or wrong-input microphone looks exactly like a working recording right
  // up until commit rejects the session — which is how the first production run
  // failed. Report what has actually been captured, as it happens.
  renderCaptureCount() {
    if (this.state !== "recording" && this.state !== "paused") return

    if (this.seq > 0) {
      this.statusHintTarget.textContent =
        `${this.seq} ${this.seq === 1 ? "phrase" : "phrases"} captured. Keep going — pauses are fine.`
      this.statusHintTarget.className = "mt-0.5 text-sm text-gray-500"
      return
    }

    const elapsed = Date.now() - this.startedAt - this.pausedMs
    if (elapsed < SILENCE_HINT_MS) return

    this.statusHintTarget.textContent =
      "Nothing heard yet — check the right microphone is selected and unmuted."
    this.statusHintTarget.className = "mt-0.5 text-sm font-medium text-amber-700"
  }

  stopTimer() {
    if (this.timerId) clearInterval(this.timerId)
    this.timerId = null
  }

  describeStartError(err) {
    if (err.name === "NotAllowedError") {
      return "Microphone access was blocked. Allow it in your browser, then press record again."
    }
    if (err.name === "NotFoundError") return "No microphone was found."
    if (!window.isSecureContext) {
      return "Recording needs a secure connection (https). This page is not on one."
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      return "This browser cannot record audio."
    }
    return err.message || "Could not start recording."
  }

  fail(message, { retryable = false } = {}) {
    this.stopTimer()
    this.setState("failed")
    this.showError(message, { retryable })
  }

  showError(message, { retryable = false } = {}) {
    this.errorMessageTarget.textContent = message
    this.errorTarget.classList.remove("hidden")
    this.retryTarget.classList.toggle("hidden", !retryable || !this.session)
  }

  hideError() {
    this.errorTarget.classList.add("hidden")
    this.retryTarget.classList.add("hidden")
  }
}
