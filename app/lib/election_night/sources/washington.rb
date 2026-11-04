class ElectionNight::Sources::Washington < ElectionNight::Sources::EnhancedVoting
  private
    def race_key(name, presidential: false)
      return super if presidential
      match = name.to_s.match(/\ACongressional District (\d+) - U\.S\. Representative\z/)
      return "WA-#{format('%02d', match[1].to_i)}" if match && state == "WA"
      super
    end

    def party_key(party)
      super(party.to_s.sub(/\A\(Prefers (.+)\)\z/, '\1'))
    end
end
