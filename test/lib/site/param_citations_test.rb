require "test_helper"

class Site::ParamCitationsTest < ActiveSupport::TestCase
  test "finds a single citation directly above a key" do
    citations = Site::ParamCitations.for(:fundamentals, :house_national_margin_2024)
    assert_equal [ "https://en.wikipedia.org/wiki/2024_United_States_House_of_Representatives_elections" ], citations
  end

  test "finds multiple citation lines stacked above one key" do
    citations = Site::ParamCitations.for(:error_model, :sigma_national)

    assert_equal 2, citations.size
    assert(citations.any? { |c| c.include?("aapor.org/wp-content/uploads/2025") })
    assert(citations.any? { |c| c.include?("aapor.org/wp-content/uploads/2022") })
  end

  test "does not bleed a citation into the next key that has none of its own" do
    # senate_holdover_dem_caucus has a citation; the very next key,
    # senate_holdover_rep, has no comment of its own above it.
    assert_equal [], Site::ParamCitations.for(:chambers, :senate_holdover_rep)
    assert_equal 1, Site::ParamCitations.for(:chambers, :senate_holdover_dem_caucus).size
  end

  test "a non-URL citation (a BUILD_NOTES pointer) is captured as plain text" do
    citations = Site::ParamCitations.for(:chambers, :vp_party)
    assert_equal [ "docs/BUILD_NOTES.md Phase 2 §A2" ], citations
  end

  test "a key with no comment at all has no citation" do
    assert_equal [], Site::ParamCitations.for(:blend, :weight_saturation)
  end

  test "an unknown section or key has no citation, rather than raising" do
    assert_equal [], Site::ParamCitations.for(:not_a_real_section, :nope)
  end

  test "the new site.* params carry the citation added alongside them" do
    citations = Site::ParamCitations.for(:site, :movers_floor_pp)
    assert_equal [ "docs/BUILD_NOTES.md Phase 3 §8.2 (10,000-sim noise measurement)" ], citations
  end

  test "reload! re-parses the file" do
    original = Site::ParamCitations.table
    reloaded = Site::ParamCitations.reload!

    assert_equal original, reloaded
    refute_same original, reloaded
  end
end
