import { Controller } from "@hotwired/stimulus"

// More opens the reference pages in a sheet. The link still points at
// #site-directory in the footer, so with no JavaScript it jumps there.
//
// A native <dialog> opened with showModal() keeps focus inside and closes
// on Escape. The close button is after the links so the first link takes
// focus.
export default class extends Controller {
  static targets = [ "dialog" ]

  open(event) {
    event.preventDefault()
    this.dialogTarget.showModal()
  }

  close() {
    this.dialogTarget.close()
  }

  // The dialog has no padding of its own, so a click whose target is the
  // dialog element itself landed on the backdrop.
  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget) this.close()
  }
}
