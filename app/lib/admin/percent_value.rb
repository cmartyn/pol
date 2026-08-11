module Admin
  # A percentage typed into the manual-entry form (Admin::PollsController) or
  # read from a CSV column (Admin::PollCsvImport) — the one shared place a
  # raw string becomes either a real Float or is deliberately left as a
  # non-Numeric value. Both callers pass the result straight into
  # Ingest::RecordPoll / Admin::UpdatePoll's results:, whose own
  # `pct.is_a?(Numeric)` validation is what actually rejects a bad value —
  # this only exists to keep String#to_f's silent "N/A" -> 0.0 out of the
  # pipeline, which would let exactly that kind of typo become a real,
  # published, wrong result instead of a validation error. Blank handling
  # stays the caller's job (both already skip a blank pct before reaching
  # this at all — a blank result means "no result for this party", not "an
  # invalid one").
  module PercentValue
    module_function

    # parse("47.5") => 47.5 (a real Float)
    # parse("N/A")  => "N/A" (unchanged — not Numeric, so RecordPoll/UpdatePoll reject it)
    def parse(raw)
      Float(raw, exception: false) || raw
    end
  end
end
