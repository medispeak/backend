require "test_helper"

class BenchScorerTest < ActiveSupport::TestCase
  test "exact, contains, any_of, number tolerance, sets, booleans and expected nulls" do
    expected = {
      "chief_complaint" => "fever and cough", "systolic_bp" => 130, "temperature" => 101.2,
      "severity" => "Moderate", "symptoms" => [ "Fever", "Cough" ], "follow_up" => true,
      "allergies" => nil, "weight" => nil
    }
    actual = {
      "chief_complaint" => "Fever with productive cough for 3 days", "systolic_bp" => "130",
      "temperature" => 101.0, "severity" => "moderate", "symptoms" => [ "cough", "FEVER" ],
      "follow_up" => "yes", "allergies" => "", "weight" => 62
    }
    rules = { "chief_complaint" => "contains:fever", "temperature" => "number_tolerance:0.5",
              "severity" => "any_of:Moderate|Medium" }

    score = Bench::Scorer.score(expected: expected, actual: actual, rules: rules)
    by_key = score[:fields].index_by(&:key)
    assert by_key["chief_complaint"].correct
    assert by_key["systolic_bp"].correct, "numeric string equals number"
    assert by_key["temperature"].correct, "within tolerance"
    assert by_key["severity"].correct
    assert by_key["symptoms"].correct, "multi-select compares as case-insensitive set"
    assert by_key["follow_up"].correct, "yes counts as true"
    assert by_key["allergies"].correct, "expected null, got blank"
    assert_not by_key["weight"].correct, "expected null, got a value"
    assert_equal 8, score[:total]
    assert_equal 7, score[:correct]
    assert_equal 0.875, score[:accuracy]
  end

  test "booleans: false matches false, 'no' matches false, true never matches false" do
    exp = { "a" => false, "b" => false, "c" => false, "d" => true, "e" => true }
    act = { "a" => false, "b" => "no", "c" => true, "d" => false, "e" => "TRUE" }
    by = Bench::Scorer.score(expected: exp, actual: act)[:fields].index_by(&:key)
    assert by["a"].correct
    assert by["b"].correct
    assert_not by["c"].correct
    assert_not by["d"].correct
    assert by["e"].correct
  end

  test "bad scoring rules fail fast instead of silently mis-scoring" do
    assert_raises(ArgumentError) { Bench::Scorer.score(expected: { "a" => "x" }, actual: { "a" => "x" }, rules: { "a" => "contain:x" }) }
    assert_raises(ArgumentError) { Bench::Scorer.score(expected: { "a" => "x" }, actual: { "a" => "x" }, rules: { "a" => "contains:" }) }
    assert_raises(ArgumentError) { Bench::Scorer.score(expected: { "a" => 1 }, actual: { "a" => 1 }, rules: { "a" => "number_tolerance" }) }
  end

  test "number_tolerance is not float-fragile at the boundary" do
    ok = Bench::Scorer.score(expected: { "a" => 1.0 }, actual: { "a" => 1.1 }, rules: { "a" => "number_tolerance:0.1" })
    assert_equal 1, ok[:correct]
  end

  test "a nil actual payload scores every non-null field wrong" do
    score = Bench::Scorer.score(expected: { "a" => 1, "b" => nil }, actual: nil)
    assert_equal 1, score[:correct]
    assert_equal 0.5, score[:accuracy]
  end
end
