import { Controller } from "@hotwired/stimulus"

// Dispatch and race pages are edge-cached, so the browser has to send the
// view. A server-side capture would miss every Cloudflare hit.
export default class extends Controller {
  static values = {
    name: String,
    properties: { type: Object, default: {} }
  }

  connect() {
    if (!this.nameValue || typeof window.posthog === "undefined") return

    window.posthog.capture(this.nameValue, this.propertiesValue)
  }
}
