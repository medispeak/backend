import { Controller } from "@hotwired/stimulus"

// Copies a value to the clipboard and confirms it on the button itself.
//
// This is used for the reveal-once API key, where a silent failure costs the
// user the key, so the copy is always confirmed visually and the failure path
// tells them to copy by hand. navigator.clipboard needs a secure context and a
// permission the browser may refuse, hence the textarea + execCommand fallback.
export default class extends Controller {
  static targets = ["source", "button"]
  static values = {
    successLabel: { type: String, default: "Copied" },
    errorLabel: { type: String, default: "Press Ctrl/Cmd+C" },
    resetDelay: { type: Number, default: 2000 }
  }

  connect() {
    this.originalLabel = this.hasButtonTarget ? this.buttonTarget.textContent : null
  }

  disconnect() {
    this.clearReset()
  }

  async copy(event) {
    if (event) event.preventDefault()

    const text = this.text
    if (!text) return

    let copied = false

    if (navigator.clipboard && window.isSecureContext) {
      try {
        await navigator.clipboard.writeText(text)
        copied = true
      } catch (error) {
        copied = false
      }
    }

    if (!copied) copied = this.fallbackCopy(text)

    this.showLabel(copied ? this.successLabelValue : this.errorLabelValue)
  }

  get text() {
    const element = this.sourceTarget
    const value = element.value != null ? element.value : element.textContent
    return (value || "").trim()
  }

  // Off-screen textarea + execCommand: deprecated, but the only copy path that
  // works without a secure context.
  fallbackCopy(text) {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    textarea.style.position = "fixed"
    textarea.style.top = "-1000px"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    textarea.setSelectionRange(0, text.length)

    let copied = false
    try {
      copied = document.execCommand("copy")
    } catch (error) {
      copied = false
    } finally {
      document.body.removeChild(textarea)
    }

    return copied
  }

  showLabel(label) {
    if (!this.hasButtonTarget) return

    this.clearReset()
    this.buttonTarget.textContent = label
    this.resetTimeout = setTimeout(() => {
      this.buttonTarget.textContent = this.originalLabel
      this.resetTimeout = null
    }, this.resetDelayValue)
  }

  clearReset() {
    if (this.resetTimeout) {
      clearTimeout(this.resetTimeout)
      this.resetTimeout = null
    }
  }
}
