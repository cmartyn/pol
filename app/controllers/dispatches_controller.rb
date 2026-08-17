# The reverse-chron feed of every published dispatch.
class DispatchesController < PublicController
  def index
    @dispatches = Dispatch.published.recent_first.includes(:race)
  end

  # Scoped to .published, so a retracted dispatch raises RecordNotFound and
  # ApplicationController renders the site's own 404 — the editor's retract
  # button says the public site will no longer show it, and this is where
  # that promise is kept. Same reason the cited polls are loaded here: the
  # site's whole claim is that every number is traceable, so the piece names
  # the polls it was written from.
  def show
    @dispatch = Dispatch.published.includes(:race).find(params[:id])
    @cited_polls = Poll.where(id: @dispatch.cited_poll_ids)
                       .includes(:pollster, :race)
                       .order(field_end: :desc)
  end
end
