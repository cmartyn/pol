require "test_helper"

class Site::FormatTest < ActiveSupport::TestCase
  # --- percent / x_in_100 --------------------------------------------------

  test "percent rounds to a whole percentage" do
    assert_equal "72%", Site::Format.percent(0.7183)
    assert_equal "0%", Site::Format.percent(0.004)
    assert_equal "100%", Site::Format.percent(1.0)
  end

  # The dashboard sets the numeral and the "%" as separate elements at
  # different sizes, so it needs the number alone — but it must be the same
  # number `percent` would print. Asserting them against each other is the
  # point: a view rounding on its own is how a figure ends up disagreeing
  # with the prose beside it.
  test "percent_value is percent without its unit, rounded identically" do
    [ 0.7183, 0.004, 1.0, 0.005, 0.9999 ].each do |probability|
      assert_equal "#{Site::Format.percent_value(probability)}%", Site::Format.percent(probability)
    end

    assert_equal "72", Site::Format.percent_value(0.7183)
    assert_equal "0", Site::Format.percent_value(0.004)
  end

  test "x_in_100 reads as a lead-sentence phrase" do
    assert_equal "72 in 100", Site::Format.x_in_100(0.7183)
    assert_equal "1 in 100", Site::Format.x_in_100(0.009)
  end

  # --- margin ---------------------------------------------------------------

  test "margin renders a positive side_a value as D+x.x" do
    assert_equal "D+3.2", Site::Format.margin(3.2, side_a_party: "dem", side_b_party: "rep")
  end

  test "margin renders a negative value with side_b's letter and a positive magnitude" do
    assert_equal "R+1.4", Site::Format.margin(-1.4, side_a_party: "dem", side_b_party: "rep")
  end

  test "margin renders exactly zero as Even" do
    assert_equal "Even", Site::Format.margin(0.0, side_a_party: "dem", side_b_party: "rep")
  end

  test "margin renders a value that rounds to zero as Even, not +0.0" do
    assert_equal "Even", Site::Format.margin(0.04, side_a_party: "dem", side_b_party: "rep")
    assert_equal "Even", Site::Format.margin(-0.04, side_a_party: "dem", side_b_party: "rep")
  end

  test "margin rounds to one decimal place" do
    assert_equal "D+3.3", Site::Format.margin(3.26, side_a_party: "dem", side_b_party: "rep")
  end

  test "margin supports an independent side_a, for the no-Democrat Senate races" do
    assert_equal "I+8.3", Site::Format.margin(8.3, side_a_party: "ind", side_b_party: "rep")
  end

  test "margin falls back to a placeholder letter for an unrecognized party" do
    assert_equal "?+5.0", Site::Format.margin(5.0, side_a_party: "mystery", side_b_party: "rep")
  end

  # --- rating_word: the tossup band and its edges ----------------------------

  test "rating_word calls a race Tossup when the leader is comfortably inside the band" do
    word = Site::Format.rating_word(p_dem_win: 0.55, p_rep_win: 0.45, p_other_win: 0.0, tossup_band_pp: 65.0)
    assert_equal "Tossup", word
  end

  test "rating_word treats the band edge itself as a Tossup (the rule is <=)" do
    word = Site::Format.rating_word(p_dem_win: 0.65, p_rep_win: 0.35, p_other_win: 0.0, tossup_band_pp: 65.0)
    assert_equal "Tossup", word
  end

  test "rating_word crosses over to Favors just above the band edge" do
    word = Site::Format.rating_word(p_dem_win: 0.6501, p_rep_win: 0.3499, p_other_win: 0.0, tossup_band_pp: 65.0)
    assert_equal "Favors Dem", word
  end

  test "rating_word favors whichever side is actually leading" do
    assert_equal "Favors Rep",
      Site::Format.rating_word(p_dem_win: 0.2, p_rep_win: 0.79, p_other_win: 0.01, tossup_band_pp: 65.0)
  end

  test "rating_word can favor a leading independent/other candidate" do
    word = Site::Format.rating_word(p_dem_win: 0.05, p_rep_win: 0.15, p_other_win: 0.80, tossup_band_pp: 65.0)
    assert_equal "Favors the independent", word
  end

  # --- percentile_interval ----------------------------------------------------

  test "percentile_interval labels the strip and formats each end as a margin" do
    percentiles = { "5" => -6.5, "25" => -0.5, "50" => 3.2, "75" => 6.9, "95" => 12.8 }

    interval = Site::Format.percentile_interval(percentiles, side_a_party: "dem", side_b_party: "rep")

    assert_equal "5th–95th", interval[:label]
    assert_equal "R+6.5", interval[:low]
    assert_equal "D+12.8", interval[:high]
  end

  test "percentile_interval accepts a custom low/high pair" do
    percentiles = { "5" => -6.5, "25" => -0.5, "50" => 3.2, "75" => 6.9, "95" => 12.8 }

    interval = Site::Format.percentile_interval(percentiles, side_a_party: "dem", side_b_party: "rep",
                                                              low: "25", high: "75")

    assert_equal "25th–75th", interval[:label]
    assert_equal "R+0.5", interval[:low]
    assert_equal "D+6.9", interval[:high]
  end

  # --- as_of -------------------------------------------------------------

  # as_of is always handed an ActiveRecord timestamp, which arrives already
  # converted into the app's zone — so the realistic input is zone-aware, not
  # a bare Time.utc. That distinction matters: strftime on a raw Time prints
  # whatever zone that object carries, so a Time.utc here would keep printing
  # "UTC" and pass no matter what config.time_zone said. Handing it a real
  # zone-aware time pins the conversion too, not just the format string.
  test "as_of renders the model-run timestamp prefix the brief specifies" do
    assert_equal "as of Aug 1, 2026, 6:00 AM EDT",
                 Site::Format.as_of(Time.utc(2026, 8, 1, 10, 0, 0).in_time_zone)
  end

  # --- last_updated ---------------------------------------------------------

  # Asserting both from one instant is the point: the header stamp and the
  # dateline beside the figures have to name the same moment in the same
  # vocabulary, differing only in the year the nav bar has no room for. Two
  # separate tests could drift into two different clocks without failing.
  test "last_updated keeps as_of's clock and zone, dropping only the year" do
    time = Time.utc(2026, 8, 1, 10, 0, 0).in_time_zone

    assert_equal "Updated Aug 1, 6:00 AM EDT", Site::Format.last_updated(time)
    assert_equal "as of Aug 1, 2026, 6:00 AM EDT", Site::Format.as_of(time)
  end
end
