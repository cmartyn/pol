# Vote reports and race calls have independent lifetimes. A certified or
# corrected editorial call takes precedence over the provider's projection.
class RaceResult < ApplicationRecord
  belongs_to :race

  def decision = editor_call || provider_call
  def status = decision&.fetch("status") || "awaiting"
  def winner = decision&.dig("winner")
  def called? = %w[projected certified].include?(status)

  def due?(now: Time.current)
    return false if status == "certified"
    return true unless status == "projected" && checked_at

    checked_at.in_time_zone.to_date < now.in_time_zone.to_date
  end

  def self.summary(chamber)
    calls = joins(:race).merge(Race.forecast_board.where(office: chamber)).pluck(:editor_call, :provider_call)
    winners = calls.filter_map { |editor, provider| (editor || provider)&.dig("winner", "party") }
    total = ForecastArchive.races.count { |_slug, row| row.fetch("chamber") == chamber }
    { parties: winners.tally, outstanding: total - winners.size, total: total }
  end

  def self.for_race!(race)
    create_or_find_by!(race: race)
  end

  # Serialize with an editor and with retries. An older report cannot undo
  # a correction, even when its retrieval happened later.
  def import!(report, fetched_at:, refresh_certified: false)
    with_lock do
      return if status == "certified" && !refresh_certified
      return if reported_at && report.fetch(:reported_at) < reported_at
      return if checked_at && fetched_at < checked_at

      before = decision
      self.votes = report.fetch(:votes)
      self.reported_at = report.fetch(:reported_at)
      self.returns_url = report.fetch(:returns_url)
      self.provider_call = report.fetch(:provider_call) if report[:provider_call]
      record_change(before)
      if changed?
        update!(checked_at: fetched_at)
      else
        update_column(:checked_at, fetched_at)
      end
    end
  end

  # Use a race-specific candidate list. A winner can be a minor or a
  # same-party finalist who did not have a separate model probability.
  def winner_choices
    observed = votes.map { |row| row.slice("name", "party") }
    roster = (race.forecast_candidates + race.candidates.to_a).map { |c| { "name" => c.name, "party" => c.party } }
    (observed + roster).uniq
  end

  def edit_call!(status:, candidate:, source_url:, decided_at:, editor:)
    with_lock do
      before = decision
      if status == "automatic"
        self.editor_call = nil
      else
        raise ArgumentError, "Choose a result status." unless %w[uncalled projected certified].include?(status)
        url = URI.parse(source_url.to_s.strip)
        raise ArgumentError, "Enter an http or https source link." unless url.is_a?(URI::HTTP) && url.host.present? && url.userinfo.nil?
        at = Time.zone.parse(decided_at.to_s)
        raise ArgumentError, "Enter the time of the decision, between poll close and now." unless at && at.between?(ElectionNight::Prior::POLL_CLOSE_CUTOFF, Time.current)
        unless status == "uncalled"
          choice = winner_choices.find { |entry| entry.to_json == candidate }
          raise ArgumentError, "Choose a candidate from this race." unless choice
        end
        self.editor_call = { "status" => status, "winner" => choice, "source" => url.host,
          "url" => url.to_s, "decided_at" => at.utc.iso8601 }
      end
      record_change(before, editor: editor)
      save!
    end
  rescue URI::InvalidURIError
    raise ArgumentError, "Enter a valid source link."
  end

  private
    def record_change(before, editor: nil)
      return if decision == before

      self.call_history += [ { "recorded_at" => Time.current.utc.iso8601, "editor_id" => editor&.id,
        "decision" => decision }.compact ]
    end
end
