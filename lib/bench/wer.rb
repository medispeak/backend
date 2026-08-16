module Bench
  # Word error rate: (substitutions + deletions + insertions) / reference words,
  # via word-level Levenshtein over normalized tokens.
  #
  # Normalization is deliberately about *rendering-equivalent* differences only,
  # so casing, punctuation, Unicode encoding forms and unit spacing don't count
  # as recognition errors, while a transliterated or different word still does:
  #   * NFC, then Malayalam legacy chillu sequences (consonant + virama + ZWJ)
  #     folded to the atomic chillu letters engines disagree on, then stray
  #     ZWJ/ZWNJ dropped;
  #   * punctuation stripped (Unicode-aware; Devanagari danda included), so
  #     "150/95", "150-95" and "150 95" all tokenize the same;
  #   * a space forced between digits and letters ("500mg" == "500 mg");
  #   * lowercased, whitespace-collapsed.
  module Wer
    PUNCT = /[[:punct:]“”‘’।॥]+/
    ZERO_WIDTH = /[‌‍]/
    DIGIT_LETTER = /(?<=\d)(?=[[:alpha:]])|(?<=[[:alpha:]])(?=\d)/
    CHILLU = {
      "ണ്‍" => "ൺ", "ന്‍" => "ൻ", "ര്‍" => "ർ",
      "ല്‍" => "ൽ", "ള്‍" => "ൾ", "ക്‍" => "ൿ"
    }.freeze

    def self.normalize(text)
      s = text.to_s.unicode_normalize(:nfc)
      CHILLU.each { |seq, atomic| s = s.gsub(seq, atomic) }
      s.gsub(ZERO_WIDTH, "").gsub(PUNCT, " ").gsub(DIGIT_LETTER, " ").downcase.split
    end

    # Returns a Hash: { wer:, errors:, ref_words:, hyp_words: }.
    def self.compute(reference, hypothesis)
      ref = normalize(reference)
      hyp = normalize(hypothesis)
      distance = levenshtein(ref, hyp)
      {
        wer: ref.empty? ? (hyp.empty? ? 0.0 : 1.0) : (distance.to_f / ref.size).round(4),
        errors: distance,
        ref_words: ref.size,
        hyp_words: hyp.size
      }
    end

    def self.levenshtein(a, b)
      return b.size if a.empty?
      return a.size if b.empty?

      prev = (0..b.size).to_a
      a.each_with_index do |wa, i|
        cur = [ i + 1 ]
        b.each_with_index do |wb, j|
          cost = wa == wb ? 0 : 1
          cur << [ prev[j + 1] + 1, cur[j] + 1, prev[j] + cost ].min
        end
        prev = cur
      end
      prev.last
    end
  end
end
