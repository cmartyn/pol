require "test_helper"

class Site::CorpusNoteTest < ActiveSupport::TestCase
  test "with no feed polls there is nothing to note" do
    note = Site::CorpusNote.new

    assert_nil note.since
    assert_nil note.expires_on
    assert_not note.visible?
  end

  test "arms itself from the first feed poll and retires after the configured run" do
    landed = Date.new(2026, 9, 3)
    create_poll(pollster: pollsters(:beacon_polling), field_end: landed - 1,
                race: races(:senate_maine), entry_mode: :nyt, created_at: landed.noon)
    create_poll(pollster: pollsters(:cardinal_research), field_end: landed,
                race: races(:senate_maine), entry_mode: :nyt, created_at: (landed + 2).noon)

    note = Site::CorpusNote.new

    assert_equal landed, note.since
    assert_equal landed + 7, note.expires_on
    assert note.visible?(on: landed)
    assert note.visible?(on: landed + 6)
    assert_not note.visible?(on: landed + 7)
  end

  test "wikipedia-era polls do not start the clock" do
    create_poll(pollster: pollsters(:beacon_polling), field_end: Date.new(2026, 8, 1),
                race: races(:senate_maine), entry_mode: :scraped, created_at: Date.new(2026, 8, 1).noon)

    assert_not Site::CorpusNote.new.visible?
  end
end
