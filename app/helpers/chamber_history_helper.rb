module ChamberHistoryHelper
  # The one sentence under "Forecast over time" that says the chart's dashed
  # lines are corrections, not voters. Return nil and the page shows no note
  # (the lines and the legend still mark where each correction falls).
  #
  #   chamber     — "senate" or "house"
  #   corrections — Site::ChamberHistory::Correction structs, oldest first.
  #                 Each has #at (the first corrected run's time) and #kinds,
  #                 a subset of:
  #                   :pollster_exclusions — a pollster's polls were removed
  #                                          from the model (or restored)
  #                   :poll_inputs         — poll records were repaired
  #                                          (Oct 26: candidates sharing a
  #                                          party kept, final ranked-choice
  #                                          rounds used)
  #                   :house_baselines     — redrawn districts got new
  #                                          baselines (Oct 25; House only)
  #
  # In production today the Senate has two (Oct 23 :pollster_exclusions,
  # Oct 26 :poll_inputs) and the House three (plus Oct 25 :house_baselines).
  def chamber_correction_note(chamber, corrections)
    return nil if corrections.empty?

    # TODO(chase): write the sentence. Site::Format and
    # `correction.at.strftime("%b %-d")` are available; return a String.
    nil
  end
end
