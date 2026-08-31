require "application_system_test_case"

# The whole loop, once, in a real browser: a poll arrives through the same door
# the scraper uses, the model re-runs because it arrived, the newsroom writes
# about it, and a reader sees all three on the page.
#
# Every other test in this suite proves one link of that chain in isolation.
# This one exists because a chain of green links is not a working chain: the
# job that hands poll ids to the newsroom, the cache key that has to change
# when a new run lands, the helper that turns 0.9935 into "D 99%" and the ERB
# that prints it are each somebody else's tested unit, and the only way to find
# out whether they add up to a page is to render one.
#
# Nothing here touches the network. Wikipedia never enters — the poll is handed
# to Ingest::RecordPoll directly, which is what the scraper does with a parsed
# row — and OpenRouter is WebMock-stubbed with a reply shaped like the real
# API's. The seed and n_sims are pinned so the numbers on the page are the same
# numbers every time this runs.
class FullPipelineTest < ApplicationSystemTestCase
  SEED = 20_260_811
  N_SIMS = 2_000

  REACTION_HEADLINE = "Harbor Analytics puts the Maine Democrat 29 points clear".freeze
  MOVEMENT_HEADLINE = "Maine Senate swings hard toward the Democrat in one week".freeze

  setup do
    @race = races(:senate_maine)
  end

  test "a poll arrives, the model re-runs, the newsroom writes it up, and the page shows all three" do
    # ---- before ------------------------------------------------------------
    # The fixture forecast: a 62-in-100 Democrat, which at a 65-point tossup
    # band the site still calls a tossup.
    visit race_path(@race.slug)

    assert_selector "[data-testid=race-name]", text: @race.name
    assert_selector "[data-testid=rating-word]", text: "Tossup"
    assert_selector "[data-testid=probability-chip]", text: "D 62%"
    assert_text "62 in 100"
    assert_no_text "Harbor Analytics"

    # ---- the poll ----------------------------------------------------------
    poll = record_poll
    before = @race.latest_forecast

    # ---- the pipeline ------------------------------------------------------
    # Ingest.after_new_polls! is the seam the scraper calls at the end of a
    # sweep. Everything downstream of it — the forecast run, the reaction, the
    # movement note the run's size earns — is queued work, performed inline
    # here in the order the queue would have run it.
    stub_the_newsroom

    with_params(simulation: { n_sims: N_SIMS }) do
      with_api_key do
        stubbing(SecureRandom, :random_number, SEED) do
          perform_enqueued_jobs { Ingest.after_new_polls!([ poll.id ]) }
        end
      end
    end

    run = ModelRun.succeeded.latest.first
    assert_equal SEED, run.rng_seed, "the run should be the pinned-seed one this test kicked off"
    assert_equal "ingest", run.trigger

    after = @race.latest_forecast
    assert_equal run.id, after.model_run_id, "the race page's forecast should come from the new run"
    assert_operator after.p_dem_win, :>, before.p_dem_win + 0.15,
                    "a D+29 poll should move the forecast far past Monte Carlo noise"
    assert_operator after.mean_margin, :>, before.mean_margin

    # .sole, not .first: exactly one reaction per race per run is the contract.
    reaction = Dispatch.published.poll_reaction.where(race: @race, model_run: run).sole
    assert_equal [ poll.id ], reaction.cited_poll_ids, "the reaction should cite the poll that caused the run"
    assert_equal REACTION_HEADLINE, reaction.headline
    assert_empty NewsroomSkip.all, "nothing should have been suppressed on this run"

    # ---- after -------------------------------------------------------------
    # The values, not the status code: the probability the run actually wrote,
    # the margin it actually estimated, the poll's own row, and the headline
    # the newsroom actually published.
    visit race_path(@race.slug)

    assert_selector "[data-testid=rating-word]", text: "Favors Dem"
    assert_selector "[data-testid=probability-chip]", text: "D #{Site::Format.percent(after.p_dem_win)}"
    assert_text Site::Format.x_in_100(after.p_dem_win)
    assert_selector "[data-testid=forecast-detail]",
                    text: Site::Format.margin(after.mean_margin, side_a_party: "dem", side_b_party: "rep")
    assert_selector "[data-testid=forecast-detail]", text: Site::Format.as_of(run.started_at)

    within "[data-testid=poll-table]" do
      assert_text "Harbor Analytics"
      assert_text "D+29.0"
    end

    # Three cards: the fixture's older reaction, plus the two this run earned —
    # a reaction to the poll and a note about the movement it caused. The
    # movement note is the newest, so the reaction is addressed by its headline
    # rather than by position.
    assert_selector "[data-testid=dispatch-card]", count: 3
    within "[data-testid=dispatch-card]", text: REACTION_HEADLINE do
      assert_text "1,500 likely voters"
      assert_text "Written autonomously by anthropic/claude-sonnet-5"
    end
    assert_selector "[data-testid=dispatch-card]", text: MOVEMENT_HEADLINE

    # The homepage is a different set of queries, a different cache key and a
    # different chamber-level number, so it gets asked separately.
    visit root_path

    within "[data-testid=dashboard-dispatches]" do
      assert_text REACTION_HEADLINE
    end
    # Case-insensitive on purpose. Capybara reads *rendered* text through the
    # driver, so a CSS text-transform on the card's label changes what this
    # sees even though the markup still says "Senate" — which is exactly how
    # this broke when the labels became uppercase eyebrows. The assertion is
    # that the chamber cards name the Senate, not how they are cased.
    assert_selector "[data-testid=chamber-cards]", text: /senate/i
    assert_text Site::Format.as_of(run.started_at)

    # And the Senate table, which reads the same forecast through a different
    # query object (Site::SenateTable) than the race page does.
    visit senate_path

    within "tr", text: @race.name do
      assert_text "D #{Site::Format.percent(after.p_dem_win)}"
    end
  end

  private
    # The same call Ingest::Nyt::Sync makes for every mapped question — the
    # feed is the corpus now, and a scraped-mode row would be filtered at the
    # after_new_polls! seam — with a poll big enough that the move it causes
    # cannot be mistaken for simulation noise.
    def record_poll
      result = Ingest::RecordPoll.call(
        { pollster_name: "Harbor Analytics", race: @race,
          field_start: Date.current - 3, field_end: Date.current,
          sample_size: 1_500, population: :lv,
          source_url: "https://example.com/polls/maine-harbor-august" },
        results: [ { party: :dem, pct: 62.0 }, { party: :rep, pct: 33.0 } ],
        entry_mode: :nyt
      )

      assert_predicate result, :created?, "the poll should have been recorded: #{result.message}"
      result.poll
    end

    # One stub for the whole run. A move this large earns two pieces — a
    # reaction to the poll and a note about the movement — so the reply is
    # keyed on the assignment line in the system prompt, and echoes the
    # payload's own citable_poll_ids back the way a compliant model would.
    # Newsroom::Validation is doing real work here: a reply citing anything
    # else would be rejected and nothing would publish.
    def stub_the_newsroom
      stub_request(:post, NewsroomStubHelper::COMPLETIONS_URL).to_return do |request|
        conversation = JSON.parse(request.body).fetch("messages").map { |message| message["content"] }.join("\n")
        movement = conversation.include?("Write a short note about this race's movement")

        { status: 200,
          headers: { "Content-Type" => "application/json" },
          body: JSON.generate(completion_response(content: dispatch_json(
            headline: movement ? MOVEMENT_HEADLINE : REACTION_HEADLINE,
            dek: "Our model now gives the Democrat a 99 in 100 chance, up from a tossup a week ago.",
            body: reaction_body,
            cited_poll_ids: citable_poll_ids(conversation)
          ))) }
      end
    end

    def citable_poll_ids(conversation)
      conversation[/"citable_poll_ids": \[([^\]]*)\]/m, 1].to_s.scan(/\d+/).map(&:to_i)
    end

    # Plain paragraphs, inside every cap Newsroom::Validation enforces — the
    # point is that a well-formed draft publishes, not that the validator can
    # be talked past.
    def reaction_body
      <<~BODY.strip
        Harbor Analytics surveyed 1,500 likely voters in Maine and found the Democrat ahead by 29 points, the
        widest margin any poll of this race has shown.

        Our average moves with it, and our model now makes the Democrat a heavy favourite for the seat. A
        single survey this far from the election is one reading, not a result.
      BODY
    end
end
