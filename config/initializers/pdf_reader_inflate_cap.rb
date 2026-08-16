# Bounds how much a single FlateDecode stream inside a PDF may inflate to.
#
# pdf-reader inflates every compressed stream it touches with
# `Zlib::Inflate.new(...).inflate(data)` — the one-shot form, which returns the
# ENTIRE inflated output as one String with no cap. Deflate compresses runs of
# identical bytes ~1000:1, and filters chain (`/Filter [/FlateDecode
# /FlateDecode]`), so a 4 KB upload can be a few gigabytes once decoded.
# PDF::Reader.new eagerly parses the xref (which may itself be a compressed
# `/Type /XRef` stream) in its constructor, and the page-tree walk in
# Api::V2::ScribeSessionsController#count_pages then reads object streams —
# every one of those inflates go through the code below.
#
# The request-thread Timeout around count_pages bounds wall-clock, not
# allocation: measured, a 3.6 KB bomb reached 2 GB of RSS in 0.7 s and the
# process was OOM-killed (prod web instances are 1 GB) before the 2 s timer
# could fire. No rescue can catch a kernel OOM kill; the allocation has to be
# prevented. So the inflate is switched to the streaming block form, which
# yields output a chunk at a time, and the stream is abandoned the moment its
# output passes MAX_INFLATED_BYTES — raising PDF::Reader::MalformedPDFError,
# which is a StandardError the existing `rescue` in count_pages already turns
# into the same clean 422 any other unreadable PDF gets.
#
# The cap is per inflate call. Page counting only needs the xref and the
# object streams that hold page dictionaries — kilobytes for a real report and
# well under a megabyte even for a very large document — so 16 MB is generous
# headroom for anything legitimate and still ~64x under the 1 GB the process
# has to live in.
#
# The override keeps the gem's own two-attempt semantics: try zlib/gzip
# auto-detect first, then raw deflate on a Zlib::Error, and return nil when
# neither works so Filter::Flate#filter can retry with the trailing byte
# dropped and finally raise its own MalformedPDFError. Only the cap escapes.
module PdfReaderInflateCap
  MAX_INFLATED_BYTES = 16.megabytes

  private

  def zlib_inflate(data)
    [ self.class::ZLIB_AUTO_DETECT_ZLIB_OR_GZIP, self.class::ZLIB_RAW_DEFLATE ].each do |window_bits|
      inflated = bounded_inflate(data, window_bits)
      return inflated if inflated
    end
    nil
  end

  def bounded_inflate(data, window_bits)
    inflater = Zlib::Inflate.new(window_bits)
    out = +""
    inflater.inflate(data) do |chunk|
      out << chunk
      if out.bytesize > MAX_INFLATED_BYTES
        raise PDF::Reader::MalformedPDFError,
              "compressed stream inflates past #{MAX_INFLATED_BYTES} bytes"
      end
    end
    out
  rescue Zlib::Error
    # Not this container format (or corrupt); the caller tries the next one.
    nil
  ensure
    # Safe on an interrupted stream; releases the zlib window now rather than
    # at GC, which matters when a hostile file makes this loop dozens of times.
    inflater&.close
  end
end

PDF::Reader::Filter::Flate.prepend(PdfReaderInflateCap)
