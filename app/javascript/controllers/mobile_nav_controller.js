import { Controller } from "@hotwired/stimulus"

// Toggles the mobile navigation panel and keeps aria-expanded in sync with it,
// so the control announces its state to assistive technology.
export default class extends Controller {
  static targets = ["menu"]

  toggle(event) {
    const hidden = this.menuTarget.classList.toggle("hidden")
    event.currentTarget.setAttribute("aria-expanded", String(!hidden))
  }
}
