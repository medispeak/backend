import { Controller } from "@hotwired/stimulus"

// The consultation's recording, played as one continuous thing.
//
// A session's audio is not always one file: the streaming ingest path stores a
// clip per stretch of speech, so this is a playlist that has to READ as a single
// track — one clock, one bar, one play button — while actually swapping the
// source between parts. Everything below follows from that:
//
//   * `offsetOf` maps session time to (part, time within part) and back, so a
//     seek can cross a boundary the listener never knew was there.
//   * Lengths arrive from the server where it knows them (ASR reports one per
//     segment) and are CORRECTED from the media element as each part loads,
//     because the server's figure can be an estimate. The bar is redrawn from
//     whatever is currently known rather than from a fixed grid.
//   * Nothing is fetched until someone presses play, unless the total length was
//     unknowable server-side — see the preload attribute in the partial.
const SKIP_SECONDS = 10
const RATES = [1, 1.25, 1.5, 2, 0.75]
const RATE_KEY = "medispeak.audioRate"

// Media time is read against a clock, not a stopwatch. Mirrors format_clock in
// UiHelper so a server-rendered timestamp and a live one agree.
function clock(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "0:00"
  const whole = Math.floor(seconds)
  const hours = Math.floor(whole / 3600)
  const minutes = Math.floor((whole % 3600) / 60)
  const secs = whole % 60
  const pad = (n) => String(n).padStart(2, "0")
  return hours > 0 ? `${hours}:${pad(minutes)}:${pad(secs)}` : `${minutes}:${pad(secs)}`
}

export default class extends Controller {
  static targets = [
    "audio", "play", "track", "fill", "thumb", "tick",
    "elapsed", "total", "rate", "row", "error"
  ]
  static values = { parts: Array, total: Number }

  connect() {
    this.parts = this.partsValue
    // null means "not known yet", which is different from zero and has to stay
    // different: an unknown length is filled in from the media element, a zero
    // one would silently swallow a part.
    this.durations = this.parts.map((part) => (part.duration > 0 ? part.duration : null))
    // The element is already pointed at the first part by the server.
    this.index = 0
    this.playing = false
    this.finished = false
    this.scrubbing = false
    this.scrubFraction = 0
    this.pendingSeek = null
    this.probed = false

    this.rate = this.storedRate()
    this.audioTarget.playbackRate = this.rate

    this.render()
  }

  disconnect() {
    // Turbo swaps this page out from under a playing recording otherwise.
    this.audioTarget.pause()
  }

  // --- transport -------------------------------------------------------------

  toggle() {
    if (this.playing) {
      this.audioTarget.pause()
      this.playing = false
      this.render()
      return
    }

    if (this.finished) {
      this.finished = false
      this.load(0, { within: 0, play: true })
      return
    }

    this.start()
  }

  back() {
    this.seekTo(this.elapsed - SKIP_SECONDS)
  }

  forward() {
    this.seekTo(this.elapsed + SKIP_SECONDS)
  }

  cycleRate() {
    const next = RATES[(RATES.indexOf(this.rate) + 1) % RATES.length]
    this.rate = next
    this.audioTarget.playbackRate = next
    this.storeRate(next)
    this.render()
  }

  // Jump to a part from the transcript list. This is the whole point of the
  // list, so it starts playing rather than merely repositioning.
  playPart(event) {
    const index = Number(event.currentTarget.dataset.index)
    if (Number.isNaN(index)) return

    this.finished = false
    this.load(index, { within: 0, play: true })
  }

  start() {
    this.playing = true
    this.clearError()
    this.render()

    const played = this.audioTarget.play()
    if (!played) return

    played.catch((error) => {
      // Seeking, or a part ending, while a play() is still resolving aborts it.
      // That is this request being superseded by the next one, not the audio
      // failing, and it must not raise an error banner at someone who is simply
      // scrubbing quickly.
      if (error?.name === "AbortError") return

      // Autoplay policy: nothing is broken, the browser just wants the gesture.
      // Fall back to a paused player rather than an alarming message.
      if (error?.name === "NotAllowedError") {
        this.playing = false
        this.render()
        return
      }

      this.fail(error)
    })
  }

  // --- media events ----------------------------------------------------------

  // Fires for both loadedmetadata and durationchange: whichever tells us the
  // real length first wins, and a correction later is applied the same way.
  partLoaded() {
    const audio = this.audioTarget
    const duration = audio.duration

    if (Number.isFinite(duration) && duration > 0) {
      this.durations[this.index] = duration
      this.applyPendingSeek()
    } else if (duration === Infinity && !this.probed) {
      // A stream written by MediaRecorder carries no duration in its header —
      // the chunked upload path stitches exactly such a file — so the browser
      // reports Infinity until it has seen the end. Seeking past any plausible
      // end forces it to go and look; applyPendingSeek then puts the playhead
      // back where it belongs once the real duration comes through.
      this.probed = true
      this.pendingSeek = this.pendingSeek ?? 0
      audio.currentTime = 1e101
    }

    this.render()
  }

  tick() {
    // Insurance for the probe above: if a browser never resolves the duration,
    // the playhead must not be left stranded at the end of time.
    if (this.probed && this.audioTarget.currentTime > 1e6) {
      this.audioTarget.currentTime = this.pendingSeek ?? 0
      this.probed = false
      this.pendingSeek = null
      return
    }

    this.render()
  }

  partEnded() {
    // Lock in what the part actually turned out to be, so a second pass over the
    // timeline stops drifting from the server's estimate.
    const measured = this.audioTarget.duration
    if (Number.isFinite(measured) && measured > 0) this.durations[this.index] = measured

    if (this.index < this.parts.length - 1) {
      this.load(this.index + 1, { within: 0, play: this.playing })
      return
    }

    this.playing = false
    this.finished = true
    this.render()
  }

  partFailed() {
    // MEDIA_ERR_ABORTED is what pausing mid-load looks like, not a failure.
    if (this.audioTarget.error && this.audioTarget.error.code === 1) return

    this.fail()
  }

  // --- seeking ---------------------------------------------------------------

  scrubStart(event) {
    if (!this.seekable) return

    event.preventDefault()
    this.trackTarget.focus()
    this.scrubbing = true
    this.scrubFraction = this.fractionFrom(event)
    this.render()
  }

  scrubMove(event) {
    if (!this.scrubbing) return

    this.scrubFraction = this.fractionFrom(event)
    this.render()
  }

  scrubEnd() {
    if (!this.scrubbing) return

    this.scrubbing = false
    this.seekTo(this.scrubFraction * this.total)
  }

  keydown(event) {
    const step = { ArrowLeft: -5, ArrowRight: 5, ArrowDown: -SKIP_SECONDS, ArrowUp: SKIP_SECONDS }[event.key]

    if (step !== undefined) {
      event.preventDefault()
      this.seekTo(this.elapsed + step)
    } else if (event.key === "Home") {
      event.preventDefault()
      this.seekTo(0)
    } else if (event.key === "End") {
      event.preventDefault()
      this.seekTo(this.total)
    } else if (event.key === " " || event.key === "Enter") {
      event.preventDefault()
      this.toggle()
    }
  }

  seekTo(seconds) {
    if (!this.seekable) return

    const target = Math.max(0, Math.min(seconds, this.total))
    const { index, within } = this.locate(target)

    this.finished = false

    if (index === this.index) {
      this.pendingSeek = null
      this.audioTarget.currentTime = within
      this.render()
    } else {
      this.load(index, { within, play: this.playing })
    }
  }

  // --- parts -----------------------------------------------------------------

  load(index, { within = 0, play = false } = {}) {
    const part = this.parts[index]
    if (!part) return

    this.index = index
    this.pendingSeek = within
    this.probed = false

    const audio = this.audioTarget
    audio.src = part.url
    audio.playbackRate = this.rate
    audio.load()

    if (play) this.start()
    else this.render()
  }

  // currentTime is ignored before the media has metadata, which is why the
  // wanted position is parked in pendingSeek and applied from partLoaded.
  applyPendingSeek() {
    if (this.pendingSeek === null) return

    const audio = this.audioTarget
    const want = Math.max(0, Math.min(this.pendingSeek, audio.duration))
    this.pendingSeek = null
    this.probed = false

    if (Math.abs(audio.currentTime - want) > 0.05) audio.currentTime = want
  }

  // --- geometry --------------------------------------------------------------

  // Only what is currently known. Unknown parts count as nothing, which is why
  // `total` prefers the server's figure while any part is still a mystery.
  get measuredTotal() {
    return this.durations.reduce((sum, duration) => sum + (duration || 0), 0)
  }

  get total() {
    if (this.durations.every((duration) => duration !== null)) return this.measuredTotal

    return this.totalValue > 0 ? this.totalValue : this.measuredTotal
  }

  get seekable() {
    return this.total > 0
  }

  get elapsed() {
    // A seek waiting on metadata is where the playhead IS, as far as anyone
    // watching is concerned. Reading currentTime instead would report the part's
    // start, so holding down an arrow key would crawl forward five seconds from
    // the same place each time instead of accumulating.
    if (this.pendingSeek !== null) return this.offsetOf(this.index) + this.pendingSeek

    const within = Number.isFinite(this.audioTarget.currentTime) ? this.audioTarget.currentTime : 0
    return this.offsetOf(this.index) + Math.min(within, this.durations[this.index] ?? within)
  }

  offsetOf(index) {
    let offset = 0
    for (let i = 0; i < index; i++) offset += this.durations[i] || 0
    return offset
  }

  locate(seconds) {
    let remaining = Math.max(0, seconds)

    for (let i = 0; i < this.parts.length; i++) {
      const duration = this.durations[i]
      const last = i === this.parts.length - 1

      if (duration === null) return { index: i, within: remaining }
      if (remaining < duration || last) return { index: i, within: Math.min(remaining, duration) }

      remaining -= duration
    }

    return { index: 0, within: 0 }
  }

  fractionFrom(event) {
    const rect = this.trackTarget.getBoundingClientRect()
    if (rect.width === 0) return 0

    return Math.min(1, Math.max(0, (event.clientX - rect.left) / rect.width))
  }

  // --- rendering -------------------------------------------------------------

  render() {
    const total = this.total
    const elapsed = this.scrubbing ? this.scrubFraction * total : this.elapsed
    const percent = total > 0 ? Math.min(100, (elapsed / total) * 100) : 0

    // Geometry is set through the CSSOM rather than as style attributes: the
    // policy in content_security_policy.rb allows no inline styles.
    this.fillTarget.style.width = `${percent}%`
    this.thumbTarget.style.left = `${percent}%`

    this.tickTargets.forEach((tick, boundary) => {
      const at = total > 0 ? (this.offsetOf(boundary + 1) / total) * 100 : 0
      tick.style.left = `${Math.min(100, at)}%`
    })

    this.elapsedTarget.textContent = clock(elapsed)
    this.totalTarget.textContent = total > 0 ? clock(total) : "--:--"
    this.rateTarget.textContent = `${this.rate}×`

    this.element.classList.toggle("ap-is-playing", this.playing)
    this.playTarget.setAttribute("aria-label", this.playing ? "Pause recording" : "Play recording")

    this.trackTarget.setAttribute("aria-valuemax", Math.round(total))
    this.trackTarget.setAttribute("aria-valuenow", Math.round(elapsed))
    this.trackTarget.setAttribute("aria-valuetext",
      total > 0 ? `${clock(elapsed)} of ${clock(total)}` : clock(elapsed))

    this.rowTargets.forEach((row, index) => {
      row.classList.toggle("ap-row-active", index === this.index)
      // Re-stamped from the corrected lengths: a server-rendered timestamp is
      // only as good as the estimate it was built from.
      const time = row.querySelector(".ap-row-time")
      if (time) time.textContent = clock(this.offsetOf(index))
    })
  }

  fail(error) {
    this.playing = false
    this.errorTarget.textContent =
      "This part of the recording could not be played. It may still be uploading, or the stored audio may be unreadable."
    this.errorTarget.classList.remove("hidden")
    this.render()

    if (error) console.warn("[audio-player]", error)
  }

  clearError() {
    this.errorTarget.classList.add("hidden")
  }

  // --- preferences -----------------------------------------------------------

  // Speed is a working habit, not a per-page choice: someone reviewing twenty
  // consultations at 1.5x should set it once. Storage can throw (private mode),
  // and a missing preference is not worth an exception.
  storedRate() {
    try {
      const stored = Number(window.localStorage.getItem(RATE_KEY))
      return RATES.includes(stored) ? stored : 1
    } catch {
      return 1
    }
  }

  storeRate(rate) {
    try {
      window.localStorage.setItem(RATE_KEY, String(rate))
    } catch {
      /* preference is a nicety; playback is not */
    }
  }
}
