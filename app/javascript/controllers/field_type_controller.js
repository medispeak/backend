import { Controller } from "@hotwired/stimulus"

// Shows the inputs relevant to the selected field type:
// - single_select / multi_select -> the options list
// - number                       -> the min/max range
export default class extends Controller {
  static targets = ["type", "options", "range"]

  connect() {
    this.toggle()
  }

  toggle() {
    const type = this.typeTarget.value
    const isSelect = type === "single_select" || type === "multi_select"
    const isNumber = type === "number"

    this.optionsTargets.forEach((el) => el.classList.toggle("hidden", !isSelect))
    this.rangeTargets.forEach((el) => el.classList.toggle("hidden", !isNumber))
  }
}
