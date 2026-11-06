module DispatchEmail
  module_function

  def enabled?
    !ForecastArchive.active? && ActiveModel::Type::Boolean.new.cast(ENV["DISPATCH_EMAILS_ENABLED"])
  end
end
