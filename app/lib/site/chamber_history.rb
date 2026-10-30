# One chamber's forecast across every succeeded model run, oldest first:
# the numbers behind the homepage card's trend line and the chamber page's
# "Forecast over time" chart. Both views read this, so they can never
# disagree about which runs exist or where a correction falls.
#
# Every run is kept. There is no smoothing and no daily sampling: a line
# that averages runs together is a story about the forecast, not the
# forecast. The views decide how to draw 1,200+ points; this only loads them.
#
# A correction is a run whose inputs differ from the run before it
# (ModelRun#input_changes_from), the same test Movers uses to refuse a
# comparison. Only the kinds that touch this chamber count: a redrawn House
# baseline changes no Senate input, so it does not mark the Senate.
module Site
  class ChamberHistory
    Row = Struct.new(:p_dem, :p_rep, :mean_seats, :histogram, keyword_init: true)
    Entry = Struct.new(:run, :excl, :incl, keyword_init: true) do
      def at = run.started_at
      def row(variant) = variant.to_sym == :incl_internals ? incl : excl
    end
    Correction = Struct.new(:run, :index, :kinds, keyword_init: true) do
      def at = run.started_at
    end

    KINDS = {
      "senate" => %i[pollster_exclusions poll_inputs],
      "house" => %i[pollster_exclusions poll_inputs house_baselines]
    }.freeze

    attr_reader :chamber

    def initialize(chamber:, seats: false)
      @chamber = chamber.to_s
      @seats = seats
    end

    def entries
      @entries ||= load_entries
    end

    def empty? = entries.empty?

    def corrections
      @corrections ||= entries.each_cons(2).with_index(1).filter_map do |(before, after), index|
        kinds = after.run.input_changes_from(before.run) & KINDS.fetch(chamber)
        Correction.new(run: after.run, index: index, kinds: kinds) if kinds.any?
      end
    end

    # The right edge of every view: the start of election day, Eastern.
    def election_at
      Time.zone.parse(Pol::Params.fetch!(:election, :date).to_s).beginning_of_day
    end

    private
      def load_entries
        runs = ModelRun.succeeded.with_input_revisions_only
          .where(id: ChamberForecast.where(chamber: chamber).select(:model_run_id))
          .order(:started_at, :id).to_a
        return [] if runs.empty?

        columns = %i[model_run_id variant p_dem_control p_rep_control mean_dem_seats]
        columns << :seat_histogram if @seats
        rows = ChamberForecast.where(chamber: chamber, model_run_id: runs.map(&:id)).pluck(*columns)
          .group_by(&:first)

        runs.filter_map do |run|
          by_variant = rows.fetch(run.id, []).to_h { |row| [ row[1].to_sym, row_from(row) ] }
          excl = by_variant[:excl_internals] or next
          Entry.new(run: run, excl: excl, incl: by_variant[:incl_internals] || excl)
        end
      end

      def row_from((_, _, p_dem, p_rep, mean_seats, histogram))
        Row.new(p_dem: p_dem, p_rep: p_rep, mean_seats: mean_seats, histogram: histogram)
      end
  end
end
