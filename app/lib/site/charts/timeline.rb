# The win-probability-over-time payload for a race page's timeline chart:
# succeeded model runs that forecast this race, oldest first. A race added
# late may have one run, so the chart (and its no-history fallback) copes
# with 0, 1 or many points rather than assuming a real time series.
#
# Every run of the last week is a point. Older runs are thinned (see
# #thinned): by late October a race had ~1,250 runs, two variants each, and
# the chart's JSON was 504 KB of a 622 KB page. Thinning keeps the shape the
# chart can draw, every step and every correction, and drops runs that sit
# on the same level as the one before.
#
# Beside the chart's own keys, two the page reads and the JSON does not
# carry (the partial strips them): :change, what just moved, per variant
# (Site::ForecastChange), and :summary, the chart in one sentence, for
# screen readers and for a page without JavaScript.
module Site
  module Charts
    class Timeline
      PAGE_ONLY_KEYS = %i[change summary].freeze

      # Runs inside this span of the newest are all kept.
      FULL_RESOLUTION = 7.days
      # A thinned run is kept once any line has moved this far since the last
      # kept one: well under a pixel on the chart.
      THIN_STEP = 0.005

      PARTIES = %w[dem rep other].freeze
      PARTY_NAME = { "dem" => "Democrats", "rep" => "Republicans", "other" => "The independent" }.freeze

      def self.build(race:)
        new(race: race).build
      end

      def initialize(race:)
        @race = race
      end

      def build
        rows = forecasts(:excl_internals).to_a
        runs = runs_for(rows)

        # The internals variant's series, aligned run-for-run with the
        # published one so the two share an x-axis. Runs from before the
        # dual-variant model wrote no internals row; the published row stands
        # in there, so toggling shows an identical (rather than missing) past.
        incl_by_run = forecasts(:incl_internals).index_by(&:model_run_id)
        incl_rows = rows.map { |forecast| incl_by_run[forecast.model_run_id] || forecast }

        baseline_runs = baseline_correction_runs(runs)
        polling_runs = polling_correction_runs(rows, runs)
        correction_runs = (baseline_runs + polling_runs).uniq.sort_by(&:started_at)
        correction_times = correction_runs.map(&:started_at)

        show_other = (rows + incl_by_run.values).any? { |forecast| forecast.p_other_win >= 0.01 }
        kept = thinned(rows, incl_rows, runs, correction_times)

        {
          baseline_corrections: dates(baseline_runs),
          polling_corrections: dates(polling_runs),
          # Where the chart rules each correction, as the chamber chart does:
          # the first run after it, so a jump there reads as a correction.
          correction_times: correction_times.map(&:iso8601),
          points: kept.map { |i| point(rows[i], runs[i], show_other) },
          # nil where the internals view matches the published one (most
          # runs, for most races); the chart reads the published point there.
          incl_points: kept.map { |i| point(incl_rows[i], runs[i], show_other) unless same?(incl_rows[i], rows[i]) },
          # A third line is only worth drawing when some point actually has a
          # visible non-major-party probability; otherwise it would just be a
          # flat line at zero cluttering the chart for the ~467 of 470 races
          # where it never happens.
          show_other: show_other,
          sparse: rows.size < 2,
          tossup_low_pct: 100.0 - tossup_band_pp,
          tossup_high_pct: tossup_band_pp,
          change: {
            excl_internals: change(rows, runs, correction_times),
            incl_internals: change(incl_rows, runs, correction_times)
          },
          summary: {
            excl_internals: summary(rows, runs),
            incl_internals: summary(incl_rows, runs)
          }
        }
      end

      private
        def baseline_correction_runs(runs)
          return [] unless Forecast::HouseBaselines.current.changed?(@race)

          runs.each_cons(2).filter_map { |before, after| after if before.baseline_revision != after.baseline_revision }
        end

        # A polling-input correction is site-wide, but it can only have moved
        # a race whose polls were in the average on one side of it or the
        # other. A race with no polls either side (Wyoming in October) gets
        # no note and no rule: its line did not move for that reason.
        def polling_correction_runs(rows, runs)
          rows.zip(runs).each_cons(2).filter_map do |(before_row, before), (after_row, after)|
            next if before.poll_input_revision == after.poll_input_revision
            next unless before_row.effective_poll_weight.positive? || after_row.effective_poll_weight.positive?

            after
          end
        end

        def dates(runs)
          runs.map { |run| run.started_at.strftime("%b %-d, %Y") }.uniq
        end

        # The indices of the runs the chart draws. Every run in the last
        # FULL_RESOLUTION, the first and last, the first run of each day (so
        # a pointer on any date reads that date), and any run where a line
        # moved THIN_STEP from the last kept one. A run kept for a move or a
        # correction also keeps the run before it, so a step stays a step
        # instead of a slope drawn back to the last kept run.
        def thinned(rows, incl_rows, runs, correction_times)
          return rows.each_index.to_a if rows.size < 3

          cutoff = runs.last.started_at - FULL_RESOLUTION
          kept = [ 0 ]
          (1...rows.size).each do |i|
            anchor = kept.last
            stepped = moved?(rows, incl_rows, anchor, i) || correction_times.include?(runs[i].started_at)
            next unless stepped || i == rows.size - 1 || runs[i].started_at >= cutoff ||
                        runs[i].started_at.to_date != runs[anchor].started_at.to_date

            kept << i - 1 if stepped && anchor != i - 1
            kept << i
          end
          kept
        end

        def moved?(rows, incl_rows, from, to)
          [ rows, incl_rows ].any? do |series|
            PARTIES.any? { |party| (probability(series[to], party) - probability(series[from], party)).abs >= THIN_STEP }
          end
        end

        def same?(one, other)
          PARTIES.all? { |party| probability(one, party).round(4) == probability(other, party).round(4) }
        end

        def probability(forecast, party)
          forecast.public_send(:"p_#{party}_win")
        end

        def change(rows, runs, correction_times)
          points = rows.zip(runs).map do |forecast, run|
            Site::ForecastChange::Point.new(time: run.started_at, probabilities: PARTIES.to_h { |party| [ party, probability(forecast, party) ] })
          end
          Site::ForecastChange.call(points, corrections: correction_times)
        end

        # "Republicans: 52% in the latest run, between 41% and 83% since
        # Aug 17, 2026." The leading side now, and its full range.
        def summary(rows, runs)
          return nil if rows.empty?

          party = Site::Format.leader(p_dem_win: rows.last.p_dem_win, p_rep_win: rows.last.p_rep_win,
                                      p_other_win: rows.last.p_other_win).first
          values = rows.map { |forecast| probability(forecast, party) }
          latest = "#{PARTY_NAME.fetch(party)}: #{Site::Format.percent(values.last)} in the latest run"
          return "#{latest}." if rows.size < 2

          low, high = values.minmax.map { |value| Site::Format.percent(value) }
          range = low == high ? "unchanged" : "between #{low} and #{high}"
          "#{latest}, #{range} since #{runs.first.started_at.strftime('%b %-d, %Y')}."
        end

        # The forecasts alone: their runs come from runs_for, which loads
        # far less of each one.
        def forecasts(variant)
          Forecast.where(variant: variant, race_id: @race.id)
            .joins(:model_run).merge(ModelRun.succeeded)
            .order("model_runs.started_at ASC")
        end

        # Each row's run, in the rows' order, with only its start time and
        # input revisions. A recent run's full snapshot is about 137 KB of
        # JSON, and a race page charts every run.
        def runs_for(rows)
          by_id = ModelRun.with_input_revisions_only.where(id: rows.map(&:model_run_id)).index_by(&:id)
          rows.map { |forecast| by_id.fetch(forecast.model_run_id) }
        end

        def tossup_band_pp
          Pol::Params.fetch!(:site, :tossup_band_pp)
        end

        def point(forecast, run, show_other)
          started_at = run.started_at
          parties = show_other ? PARTIES : PARTIES.first(2)
          {
            t: started_at.iso8601,
            # The tooltip's dateline: Site::Format.as_of's vocabulary (month,
            # day, year, 12-hour clock, zone name — Eastern throughout this
            # app, so %Z prints EDT/EST), with a middot instead of the
            # sentence comma because it heads a readout rather than running
            # in prose.
            time_label: started_at.strftime("%b %-d, %Y · %-I:%M %p %Z"),
            # Four places is a hundredth of a point, finer than the chart
            # can draw; the full float roughly doubled each point's size.
            # "Other" rides along only when its line is drawn.
            **parties.to_h { |party| [ :"p_#{party}_win", probability(forecast, party).round(4) ] },
            # Pre-formatted whole-percent strings for the tooltip rows and the
            # on-chart end labels. The payload carries the words and the JS
            # only places them — going through Site::Format.percent means the
            # chart can never round a probability differently from the prose
            # beside it.
            pct_labels: parties.to_h { |party| [ party.to_sym, Site::Format.percent(probability(forecast, party)) ] }
          }
        end
    end
  end
end
