import { Controller } from "@hotwired/stimulus"

// Group indices keep a missing/empty matchup key distinct from All matchups.
// Only table bodies change visibility; forecast and chart data stay intact.
export default class extends Controller {
  static targets = [ "select", "group", "status" ]

  connect() {
    if (this.hasSelectTarget) this.filter()
  }

  filter() {
    const selected = this.selectTarget.value
    let count = 0

    this.groupTargets.forEach((group) => {
      group.hidden = selected !== "" && group.dataset.group !== selected
      if (!group.hidden) count += Number(group.dataset.count)
    })

    this.statusTarget.textContent = `Showing ${count} ${count === 1 ? "poll" : "polls"} ${selected === "" ? "across all matchups" : "for this matchup"}.`
  }
}
