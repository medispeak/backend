import { Controller } from "@hotwired/stimulus"

// Generic add/remove for Rails nested attributes (cocoon-style, vanilla Stimulus).
//
// add():    clones the <template> target, swaps the placeholder token for a
//           unique index, and appends it to the list target.
// remove(): for a persisted record, marks its hidden _destroy field and hides
//           the row; for a new (unsaved) row, removes it from the DOM.
//
// Nesting works because remove() is index-agnostic (it walks up from the click
// to the nearest [data-nested-item]); add() resolves targets against the closest
// nested-form controller, so page-level and field-level instances stay isolated.
export default class extends Controller {
  static targets = ["list", "template"]
  static values = { placeholder: { type: String, default: "NEW_RECORD" } }

  add(event) {
    event.preventDefault()
    const unique = `${Date.now()}${Math.floor(Math.random() * 100000)}`
    const html = this.templateTarget.innerHTML.replaceAll(this.placeholderValue, unique)
    this.listTarget.insertAdjacentHTML("beforeend", html)
    const added = this.listTarget.lastElementChild
    if (added) {
      added.classList.add("nested-enter")
      requestAnimationFrame(() => added.classList.remove("nested-enter"))
      const firstField = added.querySelector("input, textarea, select")
      if (firstField) firstField.focus()
    }
  }

  remove(event) {
    event.preventDefault()
    const item = event.target.closest("[data-nested-item]")
    if (!item) return

    const destroyField = item.querySelector("input[name*='_destroy']")
    if (destroyField) {
      destroyField.value = "1"
      item.classList.add("hidden")
    } else {
      item.remove()
    }
  }
}
