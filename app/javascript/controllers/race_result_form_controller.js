import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["status", "candidate", "source", "time"]

  connect() {
    this.update()
  }

  update() {
    const automatic = this.statusTarget.value === "automatic"
    const needsWinner = ["projected", "certified"].includes(this.statusTarget.value)
    this.candidateTarget.disabled = !needsWinner
    this.candidateTarget.required = needsWinner
    for (const field of [this.sourceTarget, this.timeTarget]) {
      field.disabled = automatic
      field.required = !automatic
    }
  }
}
