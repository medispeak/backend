require "application_system_test_case"

# TEMPORARY DIAGNOSTIC — delete once the CI microphone failure is understood.
#
# The playground system tests fail on CI with "No microphone was found"
# (getUserMedia -> NotFoundError) while passing locally. Locally proves nothing:
# a developer laptop has a real microphone and --use-fake-ui-for-media-stream
# auto-grants it, so getUserMedia succeeds on hardware whether or not Chrome's
# fake device works. This reports what the CI browser actually sees.
class ZzMediaDiagnosticsTest < ApplicationSystemTestCase
  test "DIAGNOSTIC report the browser media environment" do
    visit new_user_session_path

    page.execute_script(<<~JS)
      window.__diag = {
        ua: navigator.userAgent,
        secureContext: window.isSecureContext,
        hasMediaDevices: !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia),
        devices: "pending",
        gum: "pending"
      }
      if (navigator.mediaDevices) {
        navigator.mediaDevices.enumerateDevices()
          .then((ds) => { window.__diag.devices = ds.map((d) => d.kind + "|" + (d.label || "<no label>")) })
          .catch((e) => { window.__diag.devices = "ERROR " + e.name + ": " + e.message })
        navigator.mediaDevices.getUserMedia({ audio: true })
          .then((s) => { window.__diag.gum = "OK tracks=" + s.getAudioTracks().map((t) => t.label).join(",") })
          .catch((e) => { window.__diag.gum = "ERROR " + e.name + ": " + e.message })
      } else {
        window.__diag.devices = "no navigator.mediaDevices"
        window.__diag.gum = "no navigator.mediaDevices"
      }
    JS

    20.times do
      done = page.evaluate_script("window.__diag.devices !== 'pending' && window.__diag.gum !== 'pending'")
      break if done

      sleep 0.5
    end

    diag = JSON.parse(page.evaluate_script("JSON.stringify(window.__diag)"))

    # The launch flags matter as much as the outcome: on macOS these same flags
    # are present and Chrome still hands back real hardware, so seeing them on
    # the command line proves nothing by itself — it is the pairing of flags and
    # enumerated devices that identifies the failure.
    command_line = begin
      page.driver.browser.navigate.to("chrome://version")
      sleep 1
      page.driver.browser.execute_script(
        "return document.getElementById('command_line') ? document.getElementById('command_line').textContent : ''"
      )
    rescue StandardError => e
      "unavailable: #{e.class}"
    end

    puts "\n===== MEDIA DIAGNOSTICS ====="
    puts "userAgent:      #{diag['ua']}"
    puts "secureContext:  #{diag['secureContext']}"
    puts "hasGetUserMedia:#{diag['hasMediaDevices']}"
    puts "enumerateDevices: #{diag['devices'].inspect}"
    puts "getUserMedia(audio): #{diag['gum'].inspect}"
    puts "commandLine:"
    puts "  --#{command_line.to_s.split(' --').join("\n  --")}"
    puts "============================\n"

    # Always passes: this run exists to report, not to gate.
    assert true
  end
end
