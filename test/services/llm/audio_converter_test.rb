require "test_helper"
require "mocha/minitest"

# ffmpeg-backed audio conversion for providers that reject the browser's
# WebM/Opus container. Real-binary cases run only where ffmpeg is installed
# (dev machines and the GitHub runner both have it); the logic cases run
# everywhere.
class AudioConverterTest < ActiveSupport::TestCase
  SCRATCH = Dir.mktmpdir

  def wav_fixture
    path = File.join(SCRATCH, "tone.wav")
    unless File.exist?(path)
      sr = 16_000
      data = (0...sr).map { |i| (Math.sin(2 * Math::PI * 440 * i / sr) * 12_000).to_i }.pack("s<*")
      header = "RIFF" + [ 36 + data.size ].pack("V") + "WAVE" +
               "fmt " + [ 16, 1, 1, sr, sr * 2, 2, 16 ].pack("VvvVVvv") +
               "data" + [ data.size ].pack("V")
      File.binwrite(path, header + data)
    end
    path
  end

  def encoded_fixture(ext, codec_args)
    path = File.join(SCRATCH, "tone#{ext}")
    unless File.exist?(path)
      system(Llm::AudioConverter.binary, "-y", "-loglevel", "error",
             "-i", wav_fixture, *codec_args, path)
    end
    path
  end

  test "convertible? covers the containers Azure rejects and nothing it accepts" do
    assert Llm::AudioConverter.convertible?(".webm")
    assert Llm::AudioConverter.convertible?(".m4a")
    refute Llm::AudioConverter.convertible?(".wav")
    refute Llm::AudioConverter.convertible?(".ogg")
    refute Llm::AudioConverter.convertible?(".mp3")
    refute Llm::AudioConverter.convertible?(nil)
  end

  test "to_ogg returns nil when no ffmpeg binary is available" do
    Llm::AudioConverter.stubs(:binary).returns(nil)
    File.open(wav_fixture, "rb") do |io|
      assert_nil Llm::AudioConverter.to_ogg(io, ".webm")
    end
  end

  test "remuxes webm/opus into ogg without re-encoding" do
    skip "ffmpeg not installed" unless Llm::AudioConverter.available?
    webm = encoded_fixture(".webm", [ "-c:a", "libopus", "-b:a", "24k" ])

    File.open(webm, "rb") do |io|
      ogg = Llm::AudioConverter.to_ogg(io, ".webm")
      assert ogg, "conversion returned nil"
      begin
        assert ogg.path.end_with?(".ogg")
        assert_equal "OggS", File.binread(ogg.path, 4)
      ensure
        ogg.close!
      end
    end
  end

  test "transcodes m4a/aac into ogg" do
    skip "ffmpeg not installed" unless Llm::AudioConverter.available?
    m4a = encoded_fixture(".m4a", [ "-c:a", "aac", "-b:a", "64k" ])

    File.open(m4a, "rb") do |io|
      ogg = Llm::AudioConverter.to_ogg(io, ".m4a")
      assert ogg, "conversion returned nil"
      begin
        assert_equal "OggS", File.binread(ogg.path, 4)
      ensure
        ogg.close!
      end
    end
  end

  test "garbage bytes fail cleanly with nil, never an exception" do
    skip "ffmpeg not installed" unless Llm::AudioConverter.available?
    garbage = File.join(SCRATCH, "garbage.webm")
    File.binwrite(garbage, "not audio at all")

    File.open(garbage, "rb") do |io|
      assert_nil Llm::AudioConverter.to_ogg(io, ".webm")
    end
  end
end
