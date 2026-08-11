# Builds polls for the forecast tests. The fixtures carry a small coherent
# world; the model tests need polls with specific dates, sample sizes and
# result sets, and they need them to be obviously readable at the call site.
module PollFactory
  # create_poll(pollster: pollsters(:beacon_polling), field_end: "2026-08-01",
  #             sample_size: 600, results: { dem: 50.0, rep: 44.0 })
  #
  # `results` is anything that yields [party, pct] pairs, so a hash reads well
  # for the common case and an array can carry two candidates of one party:
  # results: [ [ :dem, 47.5 ], [ :dem, 44.0 ], [ :rep, 45.0 ] ].
  def create_poll(pollster:, field_end:, race: nil, field_start: nil, sample_size: nil, results: {}, **attributes)
    poll = Poll.create!(
      pollster: pollster,
      race: race,
      field_start: field_start,
      field_end: field_end,
      sample_size: sample_size,
      source_url: "https://example.com/polls/#{SecureRandom.hex(6)}",
      entry_mode: :manual,
      dedup_digest: SecureRandom.hex(16),
      **attributes
    )
    results.each { |party, pct| poll.poll_results.create!(party: party, pct: pct) }
    poll.poll_results.reload
    poll
  end

  def create_pollster(name)
    Pollster.create!(name: name, slug: name.parameterize)
  end
end
