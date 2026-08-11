module Admin
  # CSV import: one uploaded file, every row through Admin::PollCsvImport
  # (which itself goes through Ingest::RecordPoll per row, entry_mode:
  # :csv). #create renders its own result view rather than redirecting —
  # the per-row created/duplicate/invalid breakdown IS the response, not a
  # flash message.
  class PollImportsController < BaseController
    def new
    end

    def create
      file = params[:file]
      if file.blank?
        redirect_to new_admin_poll_import_path, alert: "Choose a CSV file to upload."
        return
      end

      begin
        @results = Admin::PollCsvImport.call(file.read)
      rescue ArgumentError, EncodingError => e
        redirect_to new_admin_poll_import_path, alert: "Could not read this file as text: #{e.message}"
        return
      end

      @created = @results.select(&:created?)
      @duplicates = @results.select(&:duplicate?)
      @invalids = @results.select(&:invalid?)
    end
  end
end
