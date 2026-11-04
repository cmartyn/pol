require "test_helper"
require "tmpdir"
require "timeout"

class ElectionNight::SweepJobTest < ActiveJob::TestCase
  setup do
    @previous_enabled = ENV["ELECTION_NIGHT_ENABLED"]
    ENV["ELECTION_NIGHT_ENABLED"] = "true"
    @directory = Dir.mktmpdir
    @store = ElectionNight::Store.new(root: @directory)
    @store.write("prior", { "test" => true })
  end

  teardown do
    ENV["ELECTION_NIGHT_ENABLED"] = @previous_enabled
    FileUtils.remove_entry(@directory)
  end

  test "overlapping job succeeds without enqueueing retries or disturbing the active writer" do
    @store.write("latest", { "revision" => "previous" })
    acquired, release = Queue.new, Queue.new
    owner = Thread.new do
      @store.locked do
        acquired << true
        release.pop
        @store.write("latest", { "revision" => "active-writer" })
      end
    end
    Timeout.timeout(2) { acquired.pop }
    contender = Object.new
    store = @store
    contender.define_singleton_method(:call) do
      store.locked { raise "The overlapping job entered the protected sweep" }
    end

    begin
      stubbing(ElectionNight::Runner, :new, contender) do
        recording(Rails.logger, :info) do |messages|
          assert_no_enqueued_jobs do
            assert_nil perform_sweep
          end
          assert messages.any? { |args| args.first.to_s.include?("skipping overlapping sweep") }
        end
      end
      assert_equal "previous", @store.latest.fetch("revision")
      assert_raises(ElectionNight::Store::Busy) do
        ElectionNight::Store.new(root: @directory).locked { flunk "The losing job released the owner's lock" }
      end
    ensure
      release << true
      owner.value
    end

    assert_equal "active-writer", @store.latest.fetch("revision")
    assert_equal :next_sweep, @store.locked { :next_sweep }
  end

  test "real collection errors propagate and release the lock for the next job" do
    store = @store
    runner = Object.new
    runner.define_singleton_method(:call) { store.locked { raise "Invalid historical baseline" } }
    stubbing(ElectionNight::Runner, :new, runner) do
      error = assert_raises(RuntimeError) { perform_sweep }
      assert_equal "Invalid historical baseline", error.message
    end
    assert_equal :recovered, @store.locked { :recovered }
  end

  test "disabled collection does not create a runner" do
    ENV.delete("ELECTION_NIGHT_ENABLED")
    replacing(ElectionNight::Runner, :new, -> { flunk "Disabled collection must not start" }) do
      assert_nil ElectionNight::SweepJob.perform_now
    end
  end

  test "scheduled collection waits for a frozen prior without failing or retrying" do
    File.delete(@store.root.join("prior.json"))
    replacing(ElectionNight::Runner, :new, ->(*) { flunk "A scheduled sweep cannot run before the prior is frozen" }) do
      recording(Rails.logger, :info) do |messages|
        assert_no_enqueued_jobs { assert_nil perform_sweep }
        assert messages.any? { |args| args.first.to_s.include?("waiting for a frozen pre-election prior") }
      end
    end
    refute @store.root.join("latest.json").exist?
  end

  test "manual runner still rejects a missing prior" do
    File.delete(@store.root.join("prior.json"))
    error = assert_raises(RuntimeError) { ElectionNight::Runner.new(store: @store).call }
    assert_match(/Freeze the pre-election prior first/, error.message)
  end

  test "job stays on the dedicated election night queue" do
    assert_enqueued_with(job: ElectionNight::SweepJob, queue: "election_night") do
      ElectionNight::SweepJob.perform_later
    end
  end

  test "GoodJob drops duplicate queued and running sweeps and accepts the next sweep after completion" do
    adapter = GoodJob::Adapter.new(execution_mode: :external)
    jobs = GoodJob::Job.labeled("election-night-sweep")

    stubbing(ElectionNight::SweepJob, :queue_adapter, adapter) do
      first = ElectionNight::SweepJob.perform_later
      assert first.successfully_enqueued?
      record = jobs.find_by!(active_job_id: first.job_id)
      assert_nil record.performed_at
      assert_no_difference -> { jobs.count } do
        assert_equal false, ElectionNight::SweepJob.perform_later
      end

      record.update!(performed_at: Time.current)
      record.advisory_lock do
        assert record.advisory_locked?
        assert_no_difference -> { jobs.count } do
          assert_equal false, ElectionNight::SweepJob.perform_later
        end
      end

      record.update!(finished_at: Time.current)
      assert_difference -> { jobs.count }, 1 do
        assert ElectionNight::SweepJob.perform_later.successfully_enqueued?
      end
      assert_equal 1, jobs.unfinished.count
      assert jobs.all? { |job| job.error.nil? }
    end
  end

  private
    def perform_sweep
      stubbing(ElectionNight::Store, :new, @store) { ElectionNight::SweepJob.perform_now }
    end
end
