module Admin
  class ModelRunsController < BaseController
    def index
      @model_runs = ModelRun.latest
    end

    def show
      @model_run = ModelRun.find(params[:id])
      @previous_run = ModelRun.previous_succeeded(@model_run)
      @diff = Admin::ParamsDiff.call(current: @model_run.params_snapshot, previous: @previous_run&.params_snapshot)
    end

    # Forecast::RunJob rescues Forecast::Runner::AlreadyRunning by logging
    # and returning nil rather than raising, so enqueuing it is never a
    # promise that a run actually happens — the flash says so.
    def create
      Forecast::RunJob.perform_later(trigger: :manual)
      redirect_to admin_model_runs_path, notice: "Model run enqueued — it will decline to run if one is already in flight."
    end
  end
end
