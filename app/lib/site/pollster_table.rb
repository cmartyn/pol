# The /pollsters table: every pollster with at least one poll in the corpus,
# alongside whatever the latest succeeded run estimated about its lean.
#
# Three bulk queries however many pollsters there are — the pollsters, their
# poll counts, and the run's house_effects rows — because the page lists all
# 154 of them and an N+1 here would be 155 queries.
#
# A pollster with no house_effects row has no estimate rather than an estimate
# of zero, and the row says so: every poll it has is in an ambiguous race, or
# too isolated in time to be compared against a field. Forecast::HouseEffects
# writes no row in that case precisely so this page can tell the two apart.
module Site
  class PollsterTable
    Row = Struct.new(:pollster, :poll_count, :effect, keyword_init: true) do
      def estimated?
        !effect.nil?
      end

      def applied?
        effect&.applied || false
      end

      def residual_count
        effect&.residual_count || 0
      end

      # Sorted on the shrunk effect — the number the model would act on —
      # rather than the raw one, so the page's order matches its own point.
      def magnitude
        effect ? effect.effect_shrunk.abs : -1.0
      end
    end

    def self.build(model_run:)
      new(model_run: model_run).build
    end

    def initialize(model_run:)
      @model_run = model_run
    end

    def build
      counts = Poll.group(:pollster_id).count
      return [] if counts.empty?

      effects = @model_run ? HouseEffect.where(model_run_id: @model_run.id).index_by(&:pollster_id) : {}
      pollsters = Pollster.where(id: counts.keys).to_a

      rows = pollsters.map do |pollster|
        Row.new(pollster: pollster, poll_count: counts.fetch(pollster.id, 0), effect: effects[pollster.id])
      end

      # Largest estimated lean first; the pollsters with no estimate fall to
      # the bottom in poll-count order, where they read as a list of what the
      # estimator could not reach rather than as a run of zeroes.
      rows.sort_by { |row| [ -row.magnitude, -row.poll_count, row.pollster.name.downcase ] }
    end
  end
end
