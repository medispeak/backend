require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    # The playground records from the microphone. Without these, Chrome shows a
    # permission prompt no driver can answer and getUserMedia never resolves.
    # `use-fake-device` supplies a synthetic mic; `use-fake-ui` auto-grants the
    # permission. A test that needs real speech adds
    # `--use-file-for-fake-audio-capture=<path>.wav` on top.
    options.add_argument("--use-fake-device-for-media-capture")
    options.add_argument("--use-fake-ui-for-media-stream")
    # WebAssembly (onnxruntime, for the VAD) needs a real allocator; the
    # default headless sandbox is fine, but shared memory is not, and ort
    # probes for it during init.
    options.add_argument("--disable-dev-shm-usage")
  end
end
