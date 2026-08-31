class ScrapeRun < ApplicationRecord
  enum :status, { succeeded: 0, failed: 1, partial: 2 }

  # Same convention as ModelRun.latest / Dispatch.recent_first — Phase 6's
  # admin is the first thing that lists ScrapeRuns back to a human, so
  # "most recent first" wasn't needed as a named scope until now.
  scope :recent_first, -> { order(finished_at: :desc, id: :desc) }
  scope :refusing, -> { where(refused_count: 1..) }

  # refusal_reasons maps a machine-readable reason from
  # Ingest::PollTableParser to how many tables it fired on; refused_count is
  # how many tables that adds up to. Two of those reasons carry policy as well
  # as description:
  #
  #   EMPTY_PAGE_REASON refuses nothing. A page with no polling section had no
  #   table to turn down, so it is recorded as a reason with refused_count at
  #   zero, and a sweep of it is clean.
  #
  #   UNREADABLE_REASONS are the refusals that mean the page changed shape
  #   under us. Every other reason is a table we recognised and declined on
  #   purpose — an aggregator average, a primary field, a placeholder matchup —
  #   which is routine enough that the Georgia Senate page does it eighteen
  #   times a sweep while yielding ten real polls.
  #
  # What makes a routine refusal worth an alarm is refusing everything: a
  # source that turned down every table and read no polls has left its races
  # dark, which is the case none of this could see before.
  EMPTY_PAGE_REASON = "no_polling_section".freeze
  UNREADABLE_REASONS = %w[layout_unrecognized].freeze

  # Plain English for each machine-readable reason, so the admin page reads as
  # something other than a symbol dump. The machine name still travels with it
  # — that is the one a bug report quotes.
  REASON_LABELS = {
    "no_polling_section" => "page has no polling section",
    "aggregator_table" => "poll-aggregator average",
    "results_table" => "vote results, not a poll",
    "primary_only_table" => "primary field",
    "generic_candidate_column" => "placeholder candidate column",
    "multiple_same_party_columns" => "two candidates of one party",
    "no_party_columns" => "no party-labelled columns",
    "no_candidate_column_match" => "named nobody we hold",
    "layout_unrecognized" => "table layout not recognised",
    "district_unresolved" => "no district on the table",
    # NYT feed reasons — per question rather than per table.
    "unknown_race" => "no race on the board matches",
    "ambiguous_senate_race" => "two senate races share the state",
    "generic_candidate" => "placeholder candidate answer",
    "too_few_parties" => "fewer than two parties answered",
    "missing_field_dates" => "no usable field dates",
    "record_invalid" => "mapped but failed validation"
  }.freeze

  # [[reason, count, label], ...] — most-refused first, then alphabetical, so
  # the page is stable between runs of the same shape.
  def refusals
    refusal_reasons.sort_by { |reason, count| [ -count.to_i, reason ] }
                   .map { |reason, count| [ reason, count.to_i, REASON_LABELS.fetch(reason, reason) ] }
  end

  def refused_tables?
    refused_count.positive?
  end

  def no_polling_section?
    refusal_reasons.key?(EMPTY_PAGE_REASON)
  end

  def unreadable_refusals
    refusal_reasons.slice(*UNREADABLE_REASONS)
  end

  # Refused every table it looked at and came away with nothing.
  def dark?
    refused_tables? && fetched_count.zero?
  end

  def refusal_alarm?
    unreadable_refusals.any? || dark?
  end
end
