# The two static/derived pages: methodology (rendered straight from
# Pol::Params.to_h, per the brief) and about.
class PagesController < PublicController
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
  end

  def about
  end
end
