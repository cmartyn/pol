# The two static/derived pages: methodology (rendered straight from
# Pol::Params.to_h, per the brief) and about.
class PagesController < PublicController
  def methodology
    @params = Pol::Params.to_h
  end

  def about
  end
end
