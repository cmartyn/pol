module Ingest
  # Parses the "Date(s) administered" cell of a Wikipedia polling table.
  #
  #   Ingest::DateRange.parse("July 30 – August 2, 2026")
  #   # => [Date.new(2026, 7, 30), Date.new(2026, 8, 2)]
  #
  # Four shapes occur in practice; anything else returns nil so the caller can
  # skip and count the row rather than guess at it.
  module DateRange
    DASH = "[-–—]".freeze
    MONTH = "[A-Z][a-z]+\\.?".freeze

    # "December 29, 2025 – January 4, 2026"
    CROSS_YEAR = /\A(#{MONTH}) (\d{1,2}), (\d{4})\s*#{DASH}\s*(#{MONTH}) (\d{1,2}), (\d{4})\z/o
    # "May 15 – June 21, 2026"
    CROSS_MONTH = /\A(#{MONTH}) (\d{1,2})\s*#{DASH}\s*(#{MONTH}) (\d{1,2}), (\d{4})\z/o
    # "February 10–12, 2025"
    SAME_MONTH = /\A(#{MONTH}) (\d{1,2})\s*#{DASH}\s*(\d{1,2}), (\d{4})\z/o
    # "April 16, 2025"
    SINGLE = /\A(#{MONTH}) (\d{1,2}), (\d{4})\z/o

    MONTHS = (Date::MONTHNAMES.compact + Date::ABBR_MONTHNAMES.compact)
      .each_with_object({}) { |name, map| map[name.downcase] = Date::MONTHNAMES.index(name) || Date::ABBR_MONTHNAMES.index(name) }
      .freeze

    # Returns [field_start, field_end] or nil.
    def self.parse(text)
      value = text.to_s.tr(" ", " ").gsub(/\s+/, " ").strip
      return nil if value.empty?

      start_date, end_date =
        case value
        when CROSS_YEAR  then [ build($1, $2, $3), build($4, $5, $6) ]
        when CROSS_MONTH then [ build($1, $2, $5), build($3, $4, $5) ]
        when SAME_MONTH  then [ build($1, $2, $4), build($1, $3, $4) ]
        when SINGLE      then [ build($1, $2, $3), build($1, $2, $3) ]
        end

      return nil if start_date.nil? || end_date.nil? || end_date < start_date

      [ start_date, end_date ]
    end

    def self.build(month_name, day, year)
      month = MONTHS[month_name.to_s.delete(".").downcase]
      return nil if month.nil?

      Date.new(year.to_i, month, day.to_i)
    rescue Date::Error
      nil
    end
    private_class_method :build
  end
end
