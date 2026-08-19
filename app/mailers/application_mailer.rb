class ApplicationMailer < ActionMailer::Base
  default from: -> { ENV.fetch("MAIL_FROM", "535.wtf <robot@535.wtf>") },
          reply_to: -> { ENV.fetch("MAIL_REPLY_TO", "cmartyn@gmail.com") }
  layout "mailer"
end
