module Admin
  # Base for every /admin controller — the editor's cockpit. Deliberately
  # does nothing to weaken authentication: ApplicationController's
  # Authentication concern already requires a session by default (that's
  # what PublicController opts OUT of via allow_unauthenticated_access), so
  # "every /admin route requires authentication" falls out of this class
  # simply not calling that, rather than a check every subclass has to
  # remember to add.
  class BaseController < ApplicationController
    layout "admin"
  end
end
