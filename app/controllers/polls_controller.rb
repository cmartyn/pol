# /polls — the corpus itself: every poll the model reads, in the order it
# arrived. /pollsters publishes what the model does to the polls; this
# publishes the polls.
class PollsController < PublicController
  edge_cache

  def index
    @latest_run = ModelRun.succeeded.latest.first
    @page = Site::PollFeed.normalize_page(params[:page])

    # The one query this action pays that the view's cache block does not
    # skip, and it is free: the view's freshness key runs the identical
    # COUNT to build the fragment key, so the query cache answers this one.
    # Knowing the last page here is what lets a past-the-end request leave
    # as a redirect — never edge-cached, never a fragment — so both caches
    # only ever see page numbers that exist. That is the whole bound on how
    # many entries ?page= can mint; there is no numeric ceiling anywhere.
    last_page = Site::PollFeed.last_page(Poll.model_corpus.count)
    redirect_to polls_path(page: (last_page if last_page > 1)) if @page > last_page
  end
end
