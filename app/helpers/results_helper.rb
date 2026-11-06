module ResultsHelper
  def result_label(result)
    { "awaiting" => "Awaiting a result report", "uncalled" => "Uncalled", "under_review" => "Call under review",
      "projected" => "Projected winner", "certified" => "Certified winner" }.fetch(result&.status || "awaiting")
  end

  def result_time(value)
    time = value.in_time_zone
    tag.time(time.strftime("%b %-d, %Y, %-I:%M %p %Z"), datetime: time.iso8601)
  end
end
