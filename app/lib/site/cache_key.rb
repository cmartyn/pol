# Small, shared building blocks for the fragment-cache keys in
# app/views/{home,races}/**. The brief's Performance section keys the site's
# heavy partials on whichever of [latest succeeded model_run, latest
# dispatch, race updated_at] is relevant to what that fragment shows — most
# of that is a single ActiveRecord object (Rails already turns `cache
# model_run do` / `cache @race do` into an id+updated_at key on its own).
# The one piece with no single record to hand over is "has this whole table
# of races changed" for the Senate/House list pages, which is what this
# module is for.
module Site
  module CacheKey
    module_function

    # A cheap stand-in for "has anything in this collection of AR records
    # changed" — the newest updated_at plus the row count, so touching an
    # existing row *and* a row being added both change the key. Two small
    # aggregate queries (no LIMIT-N row load) rather than the relation's own
    # expensive builder — this is deliberately computed ahead of, and
    # independently from, Site::SenateTable/HouseTable so a fragment-cache
    # hit can skip calling either of those entirely.
    def collection_freshness(relation)
      [ relation.maximum(:updated_at), relation.count ]
    end
  end
end
