import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  reset() {
    if (typeof window.posthog !== "undefined" && typeof window.posthog.reset === "function") {
      window.posthog.reset()
    }
  }
}
