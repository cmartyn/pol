# The two static/derived pages: methodology (rendered straight from
# Pol::Params.to_h, per the brief) and about.
class PagesController < PublicController
  edge_cache

  def methodology
    @params = Pol::Params.to_h
    # M1 fix: the "Known limitations" imputed-baseline count used to be a
    # hardcoded "37 of 435 (8.5%)" in the view — a figure that goes stale the
    # moment a primary reshuffles who's actually on a House ballot. One
    # grouped count keeps the sentence honest without a second query for the
    # denominator.
    imputed_by_flag = Race.house.group(:baseline_imputed).count
    @house_district_count = imputed_by_flag.values.sum
    @house_imputed_count = imputed_by_flag[true] || 0

    # Final fixes pass: the "Unsettled nominees" bullet used to say "as of
    # the last time races were seeded," implying a future re-seed would
    # settle it — it structurally cannot, since the Senate list is a
    # hand-maintained YAML file (see Ingest::SeedRaces's class comment). Same
    # shape as the imputed-baseline count above, so the sentence reads live
    # instead of naming a number that goes stale the next time a primary is
    # called.
    unsettled_by_flag = Race.senate.group(:unsettled).count
    @senate_count = unsettled_by_flag.values.sum
    @senate_unsettled_count = unsettled_by_flag[true] || 0
  end

  def about
  end

  def privacy
  end
end
