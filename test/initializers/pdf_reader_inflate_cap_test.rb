require "test_helper"

# config/initializers/pdf_reader_inflate_cap.rb: pdf-reader's FlateDecode
# filter must not be able to inflate a stream past a fixed ceiling, because a
# few-KB PDF can decode to gigabytes and OOM the process before any wall-clock
# timeout fires.
class PdfReaderInflateCapTest < ActiveSupport::TestCase
  def flate
    PDF::Reader::Filter::Flate.new
  end

  test "an ordinary zlib stream still inflates exactly as before" do
    original = "BT /F1 12 Tf 72 712 Td (Hemoglobin 13.5 g/dL) Tj ET\n" * 200
    assert_equal original, flate.filter(Zlib::Deflate.deflate(original))
  end

  test "a raw deflate stream (no zlib header) still inflates via the second attempt" do
    original = "raw " * 1000
    raw = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS).deflate(original, Zlib::FINISH)
    assert_equal original, flate.filter(raw)
  end

  test "a stream that inflates past the cap raises MalformedPDFError instead of allocating" do
    bomb = Zlib::Deflate.deflate("\0" * (PdfReaderInflateCap::MAX_INFLATED_BYTES + 1.megabyte))
    assert_operator bomb.bytesize, :<, 100.kilobytes, "the fixture is meant to be tiny on disk"

    error = assert_raises(PDF::Reader::MalformedPDFError) { flate.filter(bomb) }
    assert_match(/inflates past/, error.message)
  end

  test "garbage is still reported by the filter's own error, not the cap" do
    error = assert_raises(PDF::Reader::MalformedPDFError) { flate.filter("this is not deflate data") }
    assert_match(/no suitable inflation algorithm/, error.message)
  end
end
