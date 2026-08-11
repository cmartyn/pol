class Session < ApplicationRecord
  belongs_to :user

  # The one lookup that turns a signed `session_id` cookie into a Session,
  # used by Authentication#find_session_by_cookie for every /admin request
  # and reused as-is by the GoodJob dashboard's gate (config/initializers/
  # good_job.rb) so the mounted engine trusts exactly the same cookie the
  # rest of the admin does, rather than a second auth mechanism.
  def self.from_signed_cookie(cookies)
    find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
  end
end
