require "test_helper"

class Ingest::Nyt::CsvParserTest < ActiveSupport::TestCase
  test "groups rows into questions in file order" do
    questions = nyt_questions(
      nyt_matchup_rows("question_id" => "q-b") +
      nyt_matchup_rows("question_id" => "q-a")
    )

    assert_equal %w[q-b q-a], questions.map(&:question_id)
    assert_equal [ 2, 2 ], questions.map { |q| q.rows.size }
  end

  test "poll-level fields read off the question" do
    question = nyt_questions(nyt_matchup_rows("pollster" => "Beacon Research")).sole

    assert_equal "Beacon Research", question.poll_field("pollster")
  end

  test "rows without a question id are dropped rather than grouped as one" do
    questions = nyt_questions(
      nyt_matchup_rows + nyt_matchup_rows("question_id" => "")
    )

    assert_equal %w[question-1], questions.map(&:question_id)
  end

  test "accented candidate names survive parsing" do
    question = nyt_questions(
      nyt_matchup_rows(dem: { "candidate_name" => "José Muñoz" })
    ).sole

    assert_equal "José Muñoz", question.rows.first["candidate_name"]
  end

  test "malformed CSV raises ParseFailed" do
    assert_raises(Ingest::Nyt::CsvParser::ParseFailed) do
      Ingest::Nyt::CsvParser.new.parse(%(a,b\n"unclosed,1\n"x",2))
    end
  end
end
