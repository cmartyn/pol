import { Controller } from "@hotwired/stimulus"

// Attaches an anonymous browser to a subscriber after they subscribe or
// unsubscribe. Leaves an editor's numeric distinct id alone so the two
// people are not merged.
export default class extends Controller {
  static values = { distinctId: String }

  connect() {
    if (!this.distinctIdValue || typeof window.posthog === "undefined") return
    if (typeof window.posthog.identify !== "function") return

    const current = typeof window.posthog.get_distinct_id === "function" ? window.posthog.get_distinct_id() : null
    if (typeof current === "string" && /^\d+$/.test(current)) return

    window.posthog.identify(this.distinctIdValue)
  }
}
