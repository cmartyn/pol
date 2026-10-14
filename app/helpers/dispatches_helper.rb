module DispatchesHelper
  KIND_COLOR = {
    "poll_reaction" => "bg-blue-50 text-blue-700",
    "movement_note" => "bg-amber-50 text-amber-700",
    "daily_brief" => "bg-slate-100 text-slate-700"
  }.freeze

  def dispatch_kind_color(kind)
    KIND_COLOR.fetch(kind, "bg-slate-100 text-slate-700")
  end

  # Public wording for who wrote a piece. The model slug stays, because the
  # site's promise is to say who claimed the sentence, but the sentence
  # itself is written for a reader rather than a log line.
  def dispatch_byline_text(dispatch)
    model = dispatch.model_slug.presence
    model ? "Written by the newsroom · #{model}" : "Written by the newsroom"
  end
end
