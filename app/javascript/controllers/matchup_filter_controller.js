import { Controller } from "@hotwired/stimulus"

// Group indices keep a missing/empty matchup key distinct from All matchups.
// Only table bodies change visibility; forecast and chart data stay intact.
//
// "current" is the default when the table holds earlier matchups as well:
// the groups that can be in this race's average (data-current), with the
// rest one choice — or the button under the table — away. The server
// renders every group, so the narrowing is this controller's alone and a
// page without JS lists every poll.
export default class extends Controller {
  static targets = [ "select", "group", "status", "more" ]

  connect() {
    if (this.hasSelectTarget) this.filter()
  }

  filter() {
    const selected = this.selectTarget.value
    let count = 0

    this.groupTargets.forEach((group) => {
      group.hidden = selected === "current"
        ? group.dataset.current !== "true"
        : selected !== "" && group.dataset.group !== selected
      if (!group.hidden) count += Number(group.dataset.count)
    })

    const polls = (n) => `${n} ${n === 1 ? "poll" : "polls"}`
    if (selected === "current") {
      const others = Number(this.statusTarget.dataset.total) - count
      this.statusTarget.textContent = `Showing ${polls(count)} of the current candidates. ${polls(others)} from other matchups ${others === 1 ? "is" : "are"} hidden.`
    } else {
      this.statusTarget.textContent = `Showing ${polls(count)} ${selected === "" ? "across all matchups" : "for this matchup"}.`
    }

    if (this.hasMoreTarget) this.moreTarget.hidden = selected !== "current"
  }

  // The button under the table: every group, and focus back on the select
  // so the reader can narrow again from where the control lives.
  showAll() {
    this.selectTarget.value = ""
    this.filter()
    this.selectTarget.focus()
  }
}
