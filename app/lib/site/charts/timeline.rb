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
        rows = forecasts.to_a
        points = rows.map { |forecast| point(forecast) }

        {
          points: points,
          # A third line is only worth drawing when some point actually has a
          # visible non-major-party probability; otherwise it would just be a
          # flat line at zero cluttering the chart for the ~467 of 470 races
          # where it never happens.
          show_other: rows.any? { |forecast| forecast.p_other_win >= 0.01 },
          sparse: points.size < 2,
          tossup_low_pct: 100.0 - tossup_band_pp,
          tossup_high_pct: tossup_band_pp
        }
      end

      private
        def forecasts
          Forecast.where(race_id: @race.id)
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
            # day, year, 12-hour clock, zone name — times are UTC throughout
            # this app), with a middot instead of the sentence comma because
            # it heads a readout rather than running in prose.
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
