require "test_helper"

class ElectionNight::CountyIdentityTest < ActiveSupport::TestCase
  test "FIPS is authoritative and name matching changes only unambiguous punctuation" do
    identity = ElectionNight::CountyIdentity.new([
      { "state" => "AR", "county_fips" => "05123", "unit_key" => "ST FRANCIS" },
      { "state" => "AR", "unit_key" => "ST. FRANCIS" },
      { "state" => "IL", "county_fips" => "17031", "unit_key" => "COOK" }
    ])
    assert_equal "ST FRANCIS", identity.normalize("AR", { "unit_key" => "St. Francis" })["unit_key"]
    assert_equal "ST FRANCIS", identity.normalize("AR", { "unit_key" => "Other spelling", "county_fips" => "05123" })["unit_key"]
    assert_not identity.normalize("AR", { "unit_key" => "ST FRANCIS", "county_fips" => "17031" })["historical_county_match"]
    assert_not identity.normalize("IL", { "unit_key" => "CHICAGO" })["historical_county_match"]
  end

  test "ambiguous normalized names and cross state names do not establish matches" do
    identity = ElectionNight::CountyIdentity.new([
      { "state" => "NC", "county_fips" => "37001", "unit_key" => "A B" },
      { "state" => "NC", "county_fips" => "37003", "unit_key" => "AB" }
    ])
    assert_not identity.normalize("NC", { "unit_key" => "A.B." })["historical_county_match"]
    assert_not identity.normalize("SC", { "unit_key" => "A B" })["historical_county_match"]
    assert identity.normalize("NC", { "unit_key" => "A.B.", "county_fips" => "37001" })["historical_county_match"]
  end

  test "binary encoded archive names normalize without mutating or dropping bytes" do
    key = "DOÑA ANA".b
    identity = ElectionNight::CountyIdentity.new([ { "state" => "NM", "county_fips" => "35013", "unit_key" => key } ])
    assert_equal key, identity.normalize("NM", { "unit_key" => "DONA ANA" }).fetch("unit_key")
    assert_equal Encoding::ASCII_8BIT, key.encoding
    assert_raises(ArgumentError) do
      identity.normalize("NM", { "unit_key" => "\xFF".b })
    end
  end
end
