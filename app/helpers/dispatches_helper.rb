module DispatchesHelper
  KIND_COLOR = {
    "poll_reaction" => "bg-blue-50 text-blue-700",
    "movement_note" => "bg-amber-50 text-amber-700",
    "daily_brief" => "bg-slate-100 text-slate-700"
  }.freeze

  def dispatch_kind_color(kind)
    KIND_COLOR.fetch(kind, "bg-slate-100 text-slate-700")
  end
end
