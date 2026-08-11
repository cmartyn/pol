class EnforceOneRunningModelRun < ActiveRecord::Migration[8.1]
  # Two forecast runs must never be in flight at once: they race each other to
  # be the latest succeeded run, and the loser's numbers can land last and
  # become the ones the site shows. Checking "is one running?" in Ruby before
  # inserting is time-of-check-to-time-of-use racy — two workers dequeued in
  # the same instant both read false. A partial unique index makes the check
  # and the insert the same operation, so the database decides, and it covers
  # every path into ModelRun (the job, bin/rails pol:model, the console) rather
  # than only the ones that remember to ask.
  #
  # The literal 0 is ModelRun.statuses["running"]; a test pins that mapping so
  # the index and the enum cannot drift apart.
  def change
    add_index :model_runs, :status, unique: true, where: "status = 0",
              name: "index_model_runs_on_single_running"
  end
end
