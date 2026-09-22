module Admin::SubscribersHelper
  def subscriber_status_class(subscriber)
    if subscriber.subscribed?
      "text-green-700"
    elsif subscriber.suppressed?
      "text-red-700"
    else
      "text-slate-500"
    end
  end
end
