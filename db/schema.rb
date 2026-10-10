# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_09_193439) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "boundaries", force: :cascade do |t|
    t.string "state", null: false
    t.integer "district"
    t.jsonb "geometry", null: false
    t.string "source_url", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["state", "district"], name: "index_boundaries_on_state_and_district", unique: true, where: "(district IS NOT NULL)"
    t.index ["state"], name: "index_boundaries_on_state_outline", unique: true, where: "(district IS NULL)"
  end

  create_table "candidates", force: :cascade do |t|
    t.bigint "race_id", null: false
    t.string "name", null: false
    t.integer "party", null: false
    t.integer "caucus_with"
    t.boolean "incumbent", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["race_id", "party"], name: "index_candidates_on_race_id_and_party"
    t.index ["race_id"], name: "index_candidates_on_race_id"
  end

  create_table "chamber_forecasts", force: :cascade do |t|
    t.bigint "model_run_id", null: false
    t.integer "chamber", null: false
    t.float "p_dem_control", null: false
    t.float "p_rep_control", null: false
    t.float "mean_dem_seats", null: false
    t.jsonb "seat_histogram"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "variant", default: 0, null: false
    t.index ["model_run_id", "chamber", "variant"], name: "idx_on_model_run_id_chamber_variant_67c6d1cb0a", unique: true
    t.index ["model_run_id"], name: "index_chamber_forecasts_on_model_run_id"
  end

  create_table "dispatch_deliveries", force: :cascade do |t|
    t.bigint "dispatch_id", null: false
    t.bigint "subscriber_id", null: false
    t.integer "status", default: 0, null: false
    t.string "resend_email_id"
    t.string "to_address"
    t.string "subject"
    t.text "html_body"
    t.text "text_body"
    t.integer "attempts", default: 0, null: false
    t.text "last_error"
    t.datetime "sent_at"
    t.datetime "delivered_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["dispatch_id", "subscriber_id"], name: "index_dispatch_deliveries_on_dispatch_id_and_subscriber_id", unique: true
    t.index ["dispatch_id"], name: "index_dispatch_deliveries_on_dispatch_id"
    t.index ["resend_email_id"], name: "index_dispatch_deliveries_on_resend_email_id", unique: true, where: "(resend_email_id IS NOT NULL)"
    t.index ["status"], name: "index_dispatch_deliveries_on_status"
    t.index ["subscriber_id"], name: "index_dispatch_deliveries_on_subscriber_id"
  end

  create_table "dispatches", force: :cascade do |t|
    t.bigint "race_id"
    t.integer "kind", null: false
    t.string "headline", null: false
    t.string "dek"
    t.text "body_markdown", null: false
    t.jsonb "cited_poll_ids", default: [], null: false
    t.bigint "model_run_id"
    t.string "model_slug"
    t.integer "status", null: false
    t.datetime "published_at"
    t.datetime "edited_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["model_run_id"], name: "index_dispatches_on_model_run_id"
    t.index ["race_id"], name: "index_dispatches_on_race_id"
    t.index ["status", "published_at"], name: "index_dispatches_on_status_and_published_at"
  end

  create_table "feed_snapshots", force: :cascade do |t|
    t.string "source", null: false
    t.string "digest", null: false
    t.binary "body", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["source", "digest"], name: "index_feed_snapshots_on_source_and_digest", unique: true
  end

  create_table "forecasts", force: :cascade do |t|
    t.bigint "model_run_id", null: false
    t.bigint "race_id", null: false
    t.float "p_dem_win", null: false
    t.float "p_rep_win", null: false
    t.float "p_other_win", default: 0.0, null: false
    t.float "mean_margin", null: false
    t.jsonb "margin_percentiles"
    t.float "effective_poll_weight", default: 0.0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "variant", default: 0, null: false
    t.index ["model_run_id", "race_id", "variant"], name: "index_forecasts_on_model_run_id_and_race_id_and_variant", unique: true
    t.index ["model_run_id"], name: "index_forecasts_on_model_run_id"
    t.index ["race_id"], name: "index_forecasts_on_race_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.index ["created_at", "id"], name: "index_good_job_batches_on_created_at_and_id", order: :desc
    t.index ["finished_at"], name: "index_good_job_batches_on_finished_at", where: "(finished_at IS NOT NULL)"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
    t.index ["scheduled_at"], name: "index_good_job_executions_on_scheduled_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
    t.integer "lock_type", limit: 2
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id_unfinished", where: "((batch_callback_id IS NOT NULL) AND (finished_at IS NULL))"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id_unfinished", where: "((batch_id IS NOT NULL) AND (finished_at IS NULL))"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_good_jobs_on_created_at"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, order: { cron_at: "DESC NULLS LAST" }, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_on_discarded", order: :desc, where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["id"], name: "index_good_jobs_on_unfinished_or_errored", where: "((finished_at IS NULL) OR (error IS NOT NULL))"
    t.index ["job_class", "finished_at"], name: "index_good_jobs_on_discarded_job_class", where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "priority", "created_at"], name: "index_good_jobs_dequeue_by_queue", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "priority", "scheduled_at"], name: "index_good_jobs_dequeue_by_queue_scheduled_at", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name"], name: "index_good_jobs_on_queue_name"
    t.index ["scheduled_at", "queue_name"], name: "index_good_jobs_on_scheduled_at_and_queue_name"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "house_effects", force: :cascade do |t|
    t.bigint "model_run_id", null: false
    t.bigint "pollster_id", null: false
    t.float "effect_raw", null: false
    t.float "effect_shrunk", null: false
    t.integer "residual_count", null: false
    t.boolean "applied", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["model_run_id", "pollster_id"], name: "index_house_effects_on_model_run_id_and_pollster_id", unique: true
    t.index ["model_run_id"], name: "index_house_effects_on_model_run_id"
    t.index ["pollster_id"], name: "index_house_effects_on_pollster_id"
  end

  create_table "model_runs", force: :cascade do |t|
    t.datetime "started_at"
    t.datetime "finished_at"
    t.integer "status", null: false
    t.jsonb "params_snapshot"
    t.bigint "rng_seed"
    t.integer "trigger", null: false
    t.text "error_message"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["status", "started_at"], name: "index_model_runs_on_status_and_started_at"
    t.index ["status"], name: "index_model_runs_on_single_running", unique: true, where: "(status = 0)"
  end

  create_table "newsroom_skips", force: :cascade do |t|
    t.integer "kind", null: false
    t.bigint "race_id"
    t.integer "reason", null: false
    t.text "detail"
    t.string "payload_digest"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_newsroom_skips_on_created_at"
    t.index ["race_id"], name: "index_newsroom_skips_on_race_id"
    t.index ["reason", "created_at"], name: "index_newsroom_skips_on_reason_and_created_at"
  end

  create_table "poll_results", force: :cascade do |t|
    t.bigint "poll_id", null: false
    t.bigint "candidate_id"
    t.integer "party", null: false
    t.float "pct", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["candidate_id"], name: "index_poll_results_on_candidate_id"
    t.index ["poll_id", "party"], name: "index_poll_results_on_poll_id_and_party"
    t.index ["poll_id"], name: "index_poll_results_on_poll_id"
  end

  create_table "polls", force: :cascade do |t|
    t.bigint "pollster_id", null: false
    t.bigint "race_id"
    t.date "field_start"
    t.date "field_end", null: false
    t.integer "sample_size"
    t.integer "population", default: 3, null: false
    t.string "sponsor"
    t.string "source_url", null: false
    t.string "dedup_digest", null: false
    t.integer "entry_mode", null: false
    t.jsonb "raw_payload"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "matchup_key"
    t.integer "partisan", default: 0, null: false
    t.string "methodology"
    t.string "nyt_poll_id"
    t.string "nyt_question_id"
    t.index ["dedup_digest"], name: "index_polls_on_dedup_digest", unique: true
    t.index ["field_end"], name: "index_polls_on_field_end"
    t.index ["nyt_poll_id"], name: "index_polls_on_nyt_poll_id"
    t.index ["nyt_question_id"], name: "index_polls_on_nyt_question_id", unique: true
    t.index ["pollster_id"], name: "index_polls_on_pollster_id"
    t.index ["race_id", "matchup_key"], name: "index_polls_on_race_id_and_matchup_key"
    t.index ["race_id"], name: "index_polls_on_race_id"
  end

  create_table "pollsters", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "nyt_pollster_id"
    t.index ["nyt_pollster_id"], name: "index_pollsters_on_nyt_pollster_id", unique: true
    t.index ["slug"], name: "index_pollsters_on_slug", unique: true
  end

  create_table "races", force: :cascade do |t|
    t.integer "office", null: false
    t.string "state", null: false
    t.integer "district"
    t.integer "cycle", default: 2026, null: false
    t.integer "seat_class"
    t.boolean "special", default: false, null: false
    t.string "slug", null: false
    t.string "incumbent_name"
    t.integer "incumbent_party"
    t.boolean "open_seat", default: false, null: false
    t.float "baseline_margin"
    t.string "baseline_source_url"
    t.boolean "baseline_imputed", default: false, null: false
    t.float "lean"
    t.boolean "uncontested", default: false, null: false
    t.integer "uncontested_party"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "unsettled", default: false, null: false
    t.index ["office"], name: "index_races_on_office"
    t.index ["slug"], name: "index_races_on_slug", unique: true
  end

  create_table "resend_webhook_events", force: :cascade do |t|
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.datetime "processed_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_resend_webhook_events_on_event_id", unique: true
  end

  create_table "scrape_runs", force: :cascade do |t|
    t.string "source", null: false
    t.integer "status", null: false
    t.integer "fetched_count", default: 0, null: false
    t.integer "new_count", default: 0, null: false
    t.integer "duplicate_count", default: 0, null: false
    t.text "error_message"
    t.datetime "started_at", null: false
    t.datetime "finished_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "refused_count", default: 0, null: false
    t.jsonb "refusal_reasons", default: {}, null: false
  end

  create_table "sessions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.string "key"
    t.string "value"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "subscribers", force: :cascade do |t|
    t.string "email_address", null: false
    t.integer "status", default: 0, null: false
    t.string "source"
    t.datetime "subscribed_at", null: false
    t.datetime "unsubscribed_at"
    t.string "suppression_reason"
    t.datetime "last_resend_event_at"
    t.integer "token_version", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email_address)::text)", name: "index_subscribers_on_lower_email_address", unique: true
    t.index ["status"], name: "index_subscribers_on_status"
  end

  create_table "users", force: :cascade do |t|
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "candidates", "races"
  add_foreign_key "chamber_forecasts", "model_runs"
  add_foreign_key "dispatch_deliveries", "dispatches"
  add_foreign_key "dispatch_deliveries", "subscribers"
  add_foreign_key "dispatches", "model_runs"
  add_foreign_key "dispatches", "races"
  add_foreign_key "forecasts", "model_runs"
  add_foreign_key "forecasts", "races"
  add_foreign_key "house_effects", "model_runs"
  add_foreign_key "house_effects", "pollsters"
  add_foreign_key "newsroom_skips", "races"
  add_foreign_key "poll_results", "candidates"
  add_foreign_key "poll_results", "polls"
  add_foreign_key "polls", "pollsters"
  add_foreign_key "polls", "races"
  add_foreign_key "sessions", "users"
end
