# Base for every unauthenticated public-facing controller — the dashboard,
# Senate/House tables, race pages, dispatches, methodology, about. The
# session-based auth ApplicationController requires by default is for
# Phase 6's admin only; the public site has no login.
class PublicController < ApplicationController
  allow_unauthenticated_access
end
