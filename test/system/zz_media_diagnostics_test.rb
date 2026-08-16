require "application_system_test_case"

# TEMPORARY DIAGNOSTIC — delete once the CI microphone failure is fixed.
#
# The playground system tests fail on CI with "No microphone was found"
# (getUserMedia -> NotFoundError) while passing locally. Locally proves nothing:
# a developer laptop has a real microphone and --use-fake-ui-for-media-stream
# auto-grants it, so getUserMedia succeeds on hardware whether or not Chrome's
# fake device works. On CI, enumerateDevices() returns [] — no devices at all,
# despite --use-fake-device-for-media-capture being on the command line
# (verified by dumping chrome://version).
#
# Each class below launches its own browser with a different flag set, so one CI
# run tests every candidate at once instead of one guess per 3-minute cycle.
module MediaProbe
  FAKE_AUDIO_WAV = Rails.root.join("test/fixtures/files/fake_audio_capture.wav").to_s

  def probe(label)
    visit new_user_session_path

    page.execute_script(<<~JS)
      window.__diag = { devices: "pending", gum: "pending" }
      navigator.mediaDevices.enumerateDevices()
        .then((ds) => { window.__diag.devices = ds.map((d) => d.kind + "|" + (d.label || "<no label>")) })
        .catch((e) => { window.__diag.devices = "ERROR " + e.name })
      navigator.mediaDevices.getUserMedia({ audio: true })
        .then((s) => { window.__diag.gum = "OK tracks=" + s.getAudioTracks().map((t) => t.label).join(",") })
        .catch((e) => { window.__diag.gum = "ERROR " + e.name + ": " + e.message })
    JS

    20.times do
      break if page.evaluate_script("window.__diag.devices !== 'pending' && window.__diag.gum !== 'pending'")

      sleep 0.5
    end

    diag = JSON.parse(page.evaluate_script("JSON.stringify(window.__diag)"))
    puts "\n[[PROBE #{label}]] devices=#{diag['devices'].inspect} gum=#{diag['gum'].inspect}"
    assert true
  end
end

# Arm A — the flags as they stand today. Expected to reproduce the CI failure.
class ZzProbeAControlTest < ApplicationSystemTestCase
  include MediaProbe
  test "A control current flags" do probe("A-control") end
end

# Arm B — force a synthetic audio source from a real file. Chromium's documented
# way to feed fake audio; the hypothesis is that it materialises an audio device
# where --use-fake-device-for-media-capture alone does not.
class ZzProbeBFakeFileTest < ActionDispatch::SystemTestCase
  include MediaProbe
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.add_argument("--use-fake-device-for-media-capture")
    options.add_argument("--use-fake-ui-for-media-stream")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--use-file-for-fake-audio-capture=#{MediaProbe::FAKE_AUDIO_WAV}")
  end
  test "B fake audio from file" do probe("B-file") end
end

# Arm C — old headless. Chrome 151 maps --headless to the new headless mode; the
# audio stack behaves differently there.
class ZzProbeCOldHeadlessTest < ActionDispatch::SystemTestCase
  include MediaProbe
  driven_by :selenium, using: :chrome, screen_size: [ 1400, 1400 ] do |options|
    options.add_argument("--headless=old")
    options.add_argument("--use-fake-device-for-media-capture")
    options.add_argument("--use-fake-ui-for-media-stream")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--no-sandbox")
  end
  test "C old headless" do probe("C-old-headless") end
end

# Arm D — run the audio service in-process. On a machine with no sound backend
# the sandboxed out-of-process audio service can come up with nothing to report.
class ZzProbeDAudioInProcessTest < ActionDispatch::SystemTestCase
  include MediaProbe
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |options|
    options.add_argument("--use-fake-device-for-media-capture")
    options.add_argument("--use-fake-ui-for-media-stream")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--disable-features=AudioServiceOutOfProcess,AudioServiceSandbox")
  end
  test "D audio service in process" do probe("D-audio-in-process") end
end
