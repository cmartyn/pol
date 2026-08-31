# The win-probability-over-time payload for a race page's timeline chart:
# one point per succeeded model run that forecast this race, oldest first.
# History is short right now — docs/BUILD_NOTES.md Phase 3 calls it "a
# handful of runs" — so the payload is exactly as sparse as the data, and the
# chart (or its no-history fallback) has to cope with 0, 1 or many points
# rather than assuming a real time series.
module Site
  module Charts
    class Timeline
      def self.build(race:)
        new(race: race).build
      end

      def initialize(race:)
        @race = race
      end

      def build
        rows = forecasts(:excl_internals).to_a
        points = rows.map { |forecast| point(forecast) }

        # The internals variant's series, aligned run-for-run with the
        # published one so the two share an x-axis. Runs from before the
        # dual-variant model wrote no internals row; the published point
        # stands in there, so toggling shows an identical (rather than
        # missing) past.
        incl_by_run = forecasts(:incl_internals).index_by(&:model_run_id)
        incl_points = rows.map { |forecast| point(incl_by_run[forecast.model_run_id] || forecast) }

        {
          points: points,
          incl_points: incl_points,
          # A third line is only worth drawing when some point actually has a
          # visible non-major-party probability; otherwise it would just be a
          # flat line at zero cluttering the chart for the ~467 of 470 races
          # where it never happens.
          show_other: (rows + incl_by_run.values).any? { |forecast| forecast.p_other_win >= 0.01 },
          sparse: points.size < 2,
          tossup_low_pct: 100.0 - tossup_band_pp,
          tossup_high_pct: tossup_band_pp
        }
      end

      private
        def forecasts(variant)
          Forecast.where(variant: variant, race_id: @race.id)
            .joins(:model_run).merge(ModelRun.succeeded)
            .includes(:model_run)
            .order("model_runs.started_at ASC")
        end

        def tossup_band_pp
          Pol::Params.fetch!(:site, :tossup_band_pp)
        end

        def point(forecast)
          started_at = forecast.model_run.started_at
          {
            t: started_at.iso8601,
            label: started_at.strftime("%b %-d"),
            # The tooltip's dateline: Site::Format.as_of's vocabulary (month,
            # day, year, 12-hour clock, zone name — Eastern throughout this
            # app, so %Z prints EDT/EST), with a middot instead of the
            # sentence comma because it heads a readout rather than running
            # in prose.
            time_label: started_at.strftime("%b %-d, %Y · %-I:%M %p %Z"),
            p_dem_win: forecast.p_dem_win,
            p_rep_win: forecast.p_rep_win,
            p_other_win: forecast.p_other_win,
            # Pre-formatted whole-percent strings for the tooltip rows and the
            # on-chart end labels. The payload carries the words and the JS
            # only places them — going through Site::Format.percent means the
            # chart can never round a probability differently from the prose
            # beside it.
            pct_labels: {
              dem: Site::Format.percent(forecast.p_dem_win),
              rep: Site::Format.percent(forecast.p_rep_win),
              other: Site::Format.percent(forecast.p_other_win)
            }
          }
        end
    end
  end
end
