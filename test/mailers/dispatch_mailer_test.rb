require "test_helper"

class DispatchMailerTest < ActionMailer::TestCase
  test "renders multipart dispatch mail with the requested identity" do
    subscriber = Subscriber.subscribe!(email_address: "friend@example.com")
    delivery = DispatchDelivery.create!(
      dispatch: dispatches(:maine_poll_reaction), subscriber: subscriber, to_address: subscriber.email_address
    )

    message = DispatchMailer.with(delivery: delivery).dispatch_update

    assert_equal [ "friend@example.com" ], message.to
    assert_equal [ "robot@535.wtf" ], message.from
    assert_equal [ "cmartyn@gmail.com" ], message.reply_to
    assert message.html_part
    assert message.text_part
    assert_includes message.html_part.body.decoded, "5305 Macomb St NW"
  end
end
