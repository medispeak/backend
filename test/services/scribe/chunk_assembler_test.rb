require "test_helper"

class Scribe::ChunkAssemblerTest < ActiveSupport::TestCase
  test "assembles chunks in seq order into one audio blob" do
    session = create(:scribe_session)
    { 2 => "world", 0 => "hel", 1 => "lo " }.each do |seq, bytes|
      c = session.audio_chunks.create!(seq: seq, content_type: "audio/webm")
      c.data.attach(io: StringIO.new(bytes), filename: "c#{seq}", content_type: "audio/webm")
    end
    assert Scribe::ChunkAssembler.assemble!(session)
    assert session.audio_files.attached?
    assert_equal "hello world", session.audio_files.first.download
    assert_equal "audio/webm", session.audio_files.first.blob.content_type
  end

  test "returns false when there are no chunks" do
    assert_equal false, Scribe::ChunkAssembler.assemble!(create(:scribe_session))
  end
end
