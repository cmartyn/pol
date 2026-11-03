require "csv"

class ElectionNight::Sources::LouisianaSenate < ElectionNight::Sources::Base
  def parse(body, metadata:)
    raise InvalidData, "Louisiana source required" unless state == "LA"
    dates = document(metadata).fetch("Dates").fetch("Date")
    election = dates.find { |date| date["PKElectionID"] == "344" }
    raise InvalidData, "missing pinned Louisiana election" unless election
    validate_date!(Date.strptime(election.fetch("ElectionDate"), "%m/%d/%Y").iso8601)
    rows = CSV.parse(body, headers: true)
    headers = Array(rows.headers)
    raise InvalidData, "unexpected parish CSV" unless headers.take(2) == %w[Office Parish] && headers.length >= 4
    candidates = headers.drop(2).map do |header|
      match = header.match(/\A(.+) \(([A-Z]+)\)\z/)
      raise InvalidData, "candidate party missing" unless match
      [ header, match[2] ]
    end
    raise InvalidData, "duplicate candidate header" unless candidates.map(&:first).uniq.size == candidates.size
    units = rows.map do |row|
      raise InvalidData, "unexpected Louisiana office" unless row["Office"] == "U. S. Senator"
      unit = empty_unit("LA-S", row.fetch("Parish"))
      candidates.each { |header, party| add_votes(unit, party, row.fetch(header)) }
      unit
    end
    raise InvalidData, "incomplete parish scaffold" unless units.map { |u| u["unit_key"] }.uniq.size == 64 && units.size == 64
    output(units).merge("election_date_basis" => "Official pinned election 344 dated November 3; date-specific Senate CSV linked by the state application.")
  rescue CSV::MalformedCSVError, Date::Error, KeyError, TypeError, NoMethodError => error
    raise InvalidData, "invalid Louisiana Senate results: #{error.message}"
  end
end
