module PollstersHelper
  # Which party's colour a house effect should carry. Same rule as
  # RacesHelper#margin_party, on the fixed dem/rep sides a house effect is
  # always measured on: an effect that rounds to zero is neutral rather than
  # quietly credited to the Republicans.
  def house_effect_party(value)
    return "other" if value.nil?

    rounded = value.round(1)
    return "other" if rounded.zero?

    rounded.positive? ? "dem" : "rep"
  end
end
