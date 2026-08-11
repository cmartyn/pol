# The reverse-chron feed of every published dispatch.
class DispatchesController < PublicController
  def index
    @dispatches = Dispatch.published.recent_first.includes(:race)
  end
end
