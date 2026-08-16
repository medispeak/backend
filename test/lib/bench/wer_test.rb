require "test_helper"

class BenchWerTest < ActiveSupport::TestCase
  test "identical text has zero WER regardless of case and punctuation" do
    r = Bench::Wer.compute("Hello, Doctor. BP is 130 over 80!", "hello doctor bp is 130 over 80")
    assert_equal 0.0, r[:wer]
    assert_equal 7, r[:ref_words]
  end

  test "counts substitutions, insertions and deletions" do
    r = Bench::Wer.compute("take one tablet twice daily", "take two tablets daily now")
    # one->two (S), tablet->tablets (S), twice deleted (D), now inserted (I) = 4 / 5
    assert_equal 4, r[:errors]
    assert_equal 0.8, r[:wer]
  end

  test "handles Devanagari and Malayalam scripts and dandas" do
    r = Bench::Wer.compute("आपका बीपी एक सौ तीस है।", "आपका बीपी एक सौ तीस है")
    assert_equal 0.0, r[:wer]
    r2 = Bench::Wer.compute("കുട്ടിക്ക് പനി ഉണ്ട്", "കുട്ടിക്ക് ചുമ ഉണ്ട്")
    assert_in_delta 1.0 / 3, r2[:wer], 0.001
  end

  test "encoding-only differences are not errors: legacy ZWJ chillu vs atomic, NFC forms, digit/unit spacing, slash vs dash" do
    # ള്‍ (LA + VIRAMA + ZWJ) renders identically to the atomic chillu ൾ
    assert_equal 0.0, Bench::Wer.compute("കുട്ടികൾ വന്നു", "കുട്ടികള്‍ വന്നു")[:wer]
    # precomposed nukta letter (U+095B) vs base + nukta (U+091C U+093C)
    assert_equal 0.0, Bench::Wer.compute("ज़रूर", "ज़रूर")[:wer]
    assert_equal 0.0, Bench::Wer.compute("paracetamol 500 mg twice daily", "Paracetamol 500mg twice daily")[:wer]
    assert_equal 0.0, Bench::Wer.compute("BP is 150/95 today", "bp is 150-95 today")[:wer]
    # ...but a genuinely different or transliterated word still counts
    assert_operator Bench::Wer.compute("back pain", "ബാക്ക് പെയിൻ")[:wer], :>, 0
  end

  test "empty hypothesis is 100% error; empty reference with empty hypothesis is 0" do
    assert_equal 1.0, Bench::Wer.compute("a b c", "")[:wer]
    assert_equal 0.0, Bench::Wer.compute("", "")[:wer]
  end
end
