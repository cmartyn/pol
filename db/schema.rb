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

ActiveRecord::Schema[8.1].define(version: 2026_08_11_040001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "candidates", force: :cascade do |t|
    t.integer "caucus_with"
    t.datetime "created_at", null: false
    t.boolean "incumbent", default: false, null: false
    t.string "name", null: false
    t.integer "party", null: false
    t.bigint "race_id", null: false
    t.datetime "updated_at", null: false
    t.index ["race_id", "party"], name: "index_candidates_on_race_id_and_party"
    t.index ["race_id"], name: "index_candidates_on_race_id"
  end

  create_table "chamber_forecasts", force: :cascade do |t|
    t.integer "chamber", null: false
    t.datetime "created_at", null: false
    t.float "mean_dem_seats", null: false
    t.bigint "model_run_id", null: false
    t.float "p_dem_control", null: false
    t.float "p_rep_control", null: false
    t.jsonb "seat_histogram"
    t.datetime "updated_at", null: false
    t.index ["model_run_id", "chamber"], name: "index_chamber_forecasts_on_model_run_id_and_chamber", unique: true
    t.index ["model_run_id"], name: "index_chamber_forecasts_on_model_run_id"
  end

  create_table "dispatches", force: :cascade do |t|
    t.text "body_markdown", null: false
    t.jsonb "cited_poll_ids", default: [], null: false
    t.datetime "created_at", null: false
    t.string "dek"
    t.datetime "edited_at"
    t.string "headline", null: false
    t.integer "kind", null: false
    t.bigint "model_run_id"
    t.string "model_slug"
    t.datetime "published_at"
    t.bigint "race_id"
    t.integer "status", null: false
    t.datetime "updated_at", null: false
    t.index ["model_run_id"], name: "index_dispatches_on_model_run_id"
    t.index ["race_id"], name: "index_dispatches_on_race_id"
    t.index ["status", "published_at"], name: "index_dispatches_on_status_and_published_at"
  end

  create_table "forecasts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.float "effective_poll_weight", default: 0.0, null: false
    t.jsonb "margin_percentiles"
    t.float "mean_margin", null: false
    t.bigint "model_run_id", null: false
    t.float "p_dem_win", null: false
    t.float "p_other_win", default: 0.0, null: false
    t.float "p_rep_win", null: false
    t.bigint "race_id", null: false
    t.datetime "updated_at", null: false
    t.index ["model_run_id", "race_id"], name: "index_forecasts_on_model_run_id_and_race_id", unique: true
    t.index ["model_run_id"], name: "index_forecasts_on_model_run_id"
    t.index ["race_id"], name: "index_forecasts_on_race_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.integer "lock_type", limit: 2
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["created_at"], name: "index_good_jobs_on_created_at"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_on_discarded", order: :desc, where: "((finished_at IS NOT NULL) AND (error IS NOT NULL))"
    t.index ["id"], name: "index_good_jobs_on_unfinished_or_errored", where: "((finished_at IS NULL) OR (error IS NOT NULL))"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["queue_name"], name: "index_good_jobs_on_queue_name"
    t.index ["scheduled_at", "queue_name"], name: "index_good_jobs_on_scheduled_at_and_queue_name"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "model_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.datetime "finished_at"
    t.jsonb "params_snapshot"
    t.bigint "rng_seed"
    t.datetime "started_at"
    t.integer "status", null: false
    t.integer "trigger", null: false
    t.datetime "updated_at", null: false
    t.index ["status", "started_at"], name: "index_model_runs_on_status_and_started_at"
    t.index ["status"], name: "index_model_runs_on_single_running", unique: true, where: "(status = 0)"
  end

  create_table "poll_results", force: :cascade do |t|
    t.bigint "candidate_id"
    t.datetime "created_at", null: false
    t.integer "party", null: false
    t.float "pct", null: false
    t.bigint "poll_id", null: false
    t.datetime "updated_at", null: false
    t.index ["candidate_id"], name: "index_poll_results_on_candidate_id"
    t.index ["poll_id", "party"], name: "index_poll_results_on_poll_id_and_party"
    t.index ["poll_id"], name: "index_poll_results_on_poll_id"
  end

  create_table "polls", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "dedup_digest", null: false
    t.integer "entry_mode", null: false
    t.date "field_end", null: false
    t.date "field_start"
    t.bigint "pollster_id", null: false
    t.integer "population", default: 3, null: false
    t.bigint "race_id"
    t.jsonb "raw_payload"
    t.integer "sample_size"
    t.string "source_url", null: false
    t.string "sponsor"
    t.datetime "updated_at", null: false
    t.index ["dedup_digest"], name: "index_polls_on_dedup_digest", unique: true
    t.index ["field_end"], name: "index_polls_on_field_end"
    t.index ["pollster_id"], name: "index_polls_on_pollster_id"
    t.index ["race_id"], name: "index_polls_on_race_id"
  end

  create_table "pollsters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_pollsters_on_slug", unique: true
  end

  create_table "races", force: :cascade do |t|
    t.boolean "baseline_imputed", default: false, null: false
    t.float "baseline_margin"
    t.string "baseline_source_url"
    t.datetime "created_at", null: false
    t.integer "cycle", default: 2026, null: false
    t.integer "district"
    t.string "incumbent_name"
    t.integer "incumbent_party"
    t.float "lean"
    t.integer "office", null: false
    t.boolean "open_seat", default: false, null: false
    t.integer "seat_class"
    t.string "slug", null: false
    t.boolean "special", default: false, null: false
    t.string "state", null: false
    t.boolean "uncontested", default: false, null: false
    t.integer "uncontested_party"
    t.datetime "updated_at", null: false
    t.index ["office"], name: "index_races_on_office"
    t.index ["slug"], name: "index_races_on_slug", unique: true
  end

  create_table "scrape_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duplicate_count", default: 0, null: false
    t.text "error_message"
    t.integer "fetched_count", default: 0, null: false
    t.datetime "finished_at", null: false
    t.integer "new_count", default: 0, null: false
    t.string "source", null: false
    t.datetime "started_at", null: false
    t.integer "status", null: false
    t.datetime "updated_at", null: false
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key"
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  add_foreign_key "candidates", "races"
  add_foreign_key "chamber_forecasts", "model_runs"
  add_foreign_key "dispatches", "model_runs"
  add_foreign_key "dispatches", "races"
  add_foreign_key "forecasts", "model_runs"
  add_foreign_key "forecasts", "races"
  add_foreign_key "poll_results", "candidates"
  add_foreign_key "poll_results", "polls"
  add_foreign_key "polls", "pollsters"
  add_foreign_key "polls", "races"
  add_foreign_key "sessions", "users"
end
