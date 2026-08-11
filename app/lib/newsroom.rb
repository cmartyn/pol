# The agent newsroom: the part of this site that writes and publishes without
# anyone approving it first.
#
# There is no editorial queue by design. What makes that safe is everything in
# this namespace: a context payload built only from our own tables, validation
# of the model's output on OUR side (Newsroom::Validation) so nothing invalid
# can reach the page, per-race and per-day caps (Newsroom::Caps), a kill switch
# (Setting.agents_enabled?) checked at the top of every job, and a row in
# newsroom_skips for every piece that didn't get written.
module Newsroom
  # America/New_York is the newsroom's clock: caps are per calendar day here,
  # and the daily brief goes out on this timezone's morning. Everything is
  # stored in UTC; this is only how days are cut.
  ZONE = "America/New_York"

  class << self
    # The seam Forecast::RunJob calls after a run succeeds — the newsroom's
    # equivalent of Ingest.after_new_polls!. Reactions only happen when the run
    # was triggered by polls arriving (poll_ids present); the movement check
    # runs after every successful run, including the 06:30 cron one, because a
    # quiet day is exactly when a slow drift becomes visible.
    def after_model_run!(model_run, poll_ids: [])
      poll_ids = Array(poll_ids)

      if poll_ids.any?
        Rails.logger.info("Newsroom: run #{model_run.id} brought #{poll_ids.size} new poll(s); queueing reactions")
        PollReactionsJob.perform_later(model_run_id: model_run.id, poll_ids: poll_ids)
      end

      MovementNotesJob.perform_later(model_run_id: model_run.id)
    end

    # Returns true when the newsroom may write; otherwise records the skip (so
    # the admin can see it went quiet on purpose) and returns false.
    #
    # Call this once per piece the newsroom would otherwise have written, AFTER
    # working out that there is one — never at the top of a job. A movement
    # check that found nothing moved is not a piece the newsroom decided
    # against, and asking here first meant every job on the schedule wrote an
    # agents_disabled row every time it ran: a dozen or more a day of "nothing
    # was going to happen anyway", burying the real skips in exactly the
    # incident where somebody is reading the list. Checking per piece also
    # means flipping the switch mid-job stops the next piece rather than
    # nothing at all.
    def clear_to_write?(kind:, race: nil)
      reason, detail = blocked

      return true if reason.nil?

      NewsroomSkip.record!(kind: kind, race: race, reason: reason, detail: detail)
      false
    end

    # [reason, detail] when the newsroom must not write at all, else [nil, nil].
    def blocked
      unless Setting.agents_enabled?
        return [ :agents_disabled, "agents_enabled is off (or AGENTS_DISABLED is set)" ]
      end

      unless Client.configured?
        return [ :no_api_key, "no OpenRouter API key is configured" ]
      end

      [ nil, nil ]
    end
  end
end
