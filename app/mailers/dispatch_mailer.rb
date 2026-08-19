class DispatchMailer < ApplicationMailer
  helper DispatchesHelper

  def dispatch_update
    @delivery = params.fetch(:delivery)
    @dispatch = @delivery.dispatch
    @subscriber = @delivery.subscriber
    @excerpt = DispatchEmail::Content.excerpt(@dispatch)
    @root_url = root_url(host: canonical_host, protocol: "https")
    @dispatch_url = dispatch_url(@dispatch, host: canonical_host, protocol: "https")
    @unsubscribe_url = unsubscribe_url(token: @subscriber.unsubscribe_token, host: canonical_host, protocol: "https")
    @postal_address = ENV.fetch("APP_POSTAL_ADDRESS", "Appmakey LLC, 5305 Macomb St NW, Washington, DC 20016")

    mail(to: @delivery.to_address || @subscriber.email_address, subject: @dispatch.headline)
  end

  private
    def canonical_host
      ENV.fetch("CANONICAL_HOST", "535.wtf")
    end
end
