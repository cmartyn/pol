module DispatchEmail
  module_function

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["DISPATCH_EMAILS_ENABLED"])
  end
end
