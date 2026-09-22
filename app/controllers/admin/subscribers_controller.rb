module Admin
  # Who receives dispatch email. The public subscribe form never confirms
  # whether an address is already on the list, so this is the only place
  # that answer exists.
  class SubscribersController < BaseController
    PAGE_SIZE = 100

    def index
      @status = params[:status].presence || "subscribed"
      @status = "all" unless @status == "all" || Subscriber.statuses.key?(@status)
      @query = params[:q].to_s.strip

      @subscribed_count = Subscriber.subscribed.count
      @unsubscribed_count = Subscriber.unsubscribed.count
      @suppressed_count = Subscriber.suppressed.count

      scope = Subscriber.all
      scope = scope.where(status: @status) unless @status == "all"
      if @query.present?
        scope = scope.where(
          "email_address LIKE ?",
          "%#{Subscriber.sanitize_sql_like(@query.downcase)}%"
        )
      end

      @page = [ params[:page].to_i, 1 ].max
      @total = scope.count
      @subscribers = scope.order(subscribed_at: :desc, id: :desc)
                          .offset((@page - 1) * PAGE_SIZE)
                          .limit(PAGE_SIZE)
    end

    def show
      @subscriber = Subscriber.find(params[:id])
      @deliveries = @subscriber.dispatch_deliveries.includes(:dispatch).order(id: :desc).limit(50)
    end
  end
end
