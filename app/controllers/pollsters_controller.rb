# /pollsters — every pollster in the corpus and the lean the model estimated
# for it. Phase 9's publication half: the adjustment is only defensible if a
# reader can see it, so every number that goes into it is on this page,
# including the ones the model decided not to act on.
class PollstersController < PublicController
  def index
    @latest_run = ModelRun.succeeded.latest.first
    # Site::PollsterTable.build runs inside the view's `cache` block, so a
    # cache hit skips its three queries entirely — same shape as /senate.
  end
end
