# /pollsters — every pollster in the corpus and the lean the model estimated
# for it. Phase 9's publication half: the adjustment is only defensible if a
# reader can see it, so every number that goes into it is on this page,
# including the ones the model decided not to act on.
class PollstersController < PublicController
  edge_cache

  def index
    @latest_run = ModelRun.succeeded.latest.first
    # Site::PollsterTable.build runs inside the view's `cache` block, so a
    # cache hit skips its three queries entirely — same shape as /senate.
  end

  def show
    @pollster = Pollster.find(params[:id])
    @page = Site::PollFeed.normalize_page(params[:page])
    @feed = Site::PollFeed.build(page: @page, scope: @pollster.polls.from_current_sources)
    redirect_to pollster_path(@pollster, page: (@feed.pages if @feed.pages > 1)) if @page > @feed.pages
  end
end
