import { Controller } from "@hotwired/stimulus"

// The header's Subscribe link opens the signup in a modal instead of jumping
// to the footer, which on a long page like /house is a long way from where
// the reader was. The link's href still points at the footer's form, so with
// no JS it goes there, as it always did.
//
// A native <dialog> opened with showModal() does the hard parts itself: it
// keeps focus inside, closes on Escape, and focuses the first focusable
// element — the email field, since the close button comes after the form.
export default class extends Controller {
  static targets = ["dialog"]

  open(event) {
    event.preventDefault()
    this.dialogTarget.showModal()
    // Opens against subscriptions with source "dialog" make the funnel.
    window.posthog?.capture("subscribe_dialog_opened", { path: window.location.pathname })
  }

  close() {
    this.dialogTarget.close()
  }

  // The dialog has no padding of its own (its inner wrapper does), so a
  // click whose target is the dialog element itself landed on the backdrop.
  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
