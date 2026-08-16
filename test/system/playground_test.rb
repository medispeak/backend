require "application_system_test_case"

# The playground is the app's only microphone-driven surface, and the riskiest
# part of it — a vendored WebAssembly VAD loading under the app's CSP, against a
# real getUserMedia — cannot be verified any other way. These tests drive a real
# headless Chrome with a synthetic microphone.
#
# They stop at "recording has started". Going further would mean stubbing a
# provider for ASR and settling background jobs, which the integration and
# service suites already cover without a browser.
class PlaygroundTest < ApplicationSystemTestCase
  # Sign in through Warden rather than the sign-in form: driving the form makes
  # every test here depend on a CSRF token surviving Turbo's page cache across
  # examples, which is a failure mode that has nothing to do with the recorder.
  include Warden::Test::Helpers

  setup do
    Warden.test_mode!
    @user = create(:user)
    @account = @user.account

    @template = create(:template, account: @account, name: "Consultation note")
    @page = create(:page, template: @template, name: "History")
    create(:form_field, page: @page, title: "chief_complaint",
                        friendly_name: "Chief complaint", field_type: "string")

    login_as @user, scope: :user
  end

  teardown { Warden.test_reset! }

  # The GitHub runner has no audio hardware and no sound server, so Chrome
  # enumerates ZERO capture devices there and getUserMedia rejects with
  # NotFoundError ("No microphone was found" is what the screenshot artifact
  # shows). That is not a browser-flag problem: --use-fake-device-for-media-capture
  # and --use-fake-ui-for-media-stream are both on the command line on CI
  # (confirmed from chrome://version), and adding --use-file-for-fake-audio-capture,
  # forcing old headless, or running the audio service in-process all still
  # enumerate nothing. Giving CI a real microphone means provisioning a virtual
  # sound backend on the runner, which is more machinery than this coverage is
  # worth.
  #
  # So these run on a developer machine, which has a microphone, and are skipped
  # on CI. They are NOT deleted: they exist because a production run once
  # recorded for thirty seconds and uploaded nothing, and they are the only thing
  # that exercises the vendored WASM VAD against a real getUserMedia. Run them
  # before touching the recorder:  bin/rails test:system
  def skip_without_microphone
    skip "needs a real microphone; the CI runner has no audio device" if ENV["CI"].present?
  end

  test "the template page offers a way to try it" do
    visit template_path(@template)
    assert_link "Try it"

    click_on "Try it"
    assert_selector "h1", text: "Try #{@template.name}"
  end

  test "fields are listed as empty rows waiting to fill" do
    visit template_playground_path(@template)

    # Case-insensitive: the label is upper-cased in CSS, so the rendered text
    # Capybara sees is "CHIEF COMPLAINT".
    assert_selector "[data-field-key='chief_complaint']", text: /chief complaint/i
    assert_selector "[data-field-key='chief_complaint'] .pg-field-value", text: "—"
    assert_selector "button[aria-label='Start recording']"
  end

  test "pressing record loads the VAD, opens the mic and starts a session" do
    skip_without_microphone
    visit template_playground_path(@template)

    assert_difference -> { ScribeSession.count }, 1 do
      find("button[aria-label='Start recording']").click

      # Loading ~12MB of vendored wasm and acquiring the mic is genuinely slow
      # on a cold cache, so this waits well past Capybara's default.
      assert_selector "button[aria-label='Stop recording']", wait: 30
    end

    assert_text "Listening"
    assert_selector ".pg-orb-recording"
    assert_selector "[data-playground-target='timer']", visible: true

    # The run was declared against the template's page, exactly as a production
    # integration would declare it.
    session = ScribeSession.order(:id).last
    assert_equal @account, session.account
    assert_equal @user, session.user
    assert_equal [ @page.id ], session.scribe_outputs.map(&:page_id)

    # No CSP violation: onnxruntime compiled its wasm, which a bare
    # `script_src :self` would have blocked.
    assert page.evaluate_script("typeof window.vad !== 'undefined'")
  end

  # The first production run recorded for thirty seconds, uploaded nothing, and
  # died at commit with "No audio uploaded for this session" — a silent failure
  # with no signal to the user until the very end.
  #
  # This asserts audio genuinely reaches the VAD. NOTE the probe is injected by
  # wrapping MicVAD.new: `vad.setOptions` looks like it would work and does not.
  # It writes to frameProcessor.options, while the callback actually invoked is
  # the one captured in AudioNodeVAD.options at construction
  # (real-time-vad.js:181 vs :206). Probing via setOptions reports zero frames
  # on a perfectly healthy recorder — it cost a wrong diagnosis once already.
  test "audio actually reaches the VAD once recording starts" do
    skip_without_microphone
    visit template_playground_path(@template)

    page.execute_script(<<~JS)
      window.__probeReady = false
      window.__frames = { count: 0, peak: 0 }
      const controller = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="playground"]'), 'playground')
      controller.loadVad().then(() => {
        const original = window.vad.MicVAD.new.bind(window.vad.MicVAD)
        window.vad.MicVAD.new = (options) => original({ ...options,
          onFrameProcessed: (_probabilities, frame) => {
            window.__frames.count++
            for (let i = 0; i < frame.length; i++) {
              const amplitude = Math.abs(frame[i])
              if (amplitude > window.__frames.peak) window.__frames.peak = amplitude
            }
          }
        })
        window.__probeReady = true
      })
    JS

    30.times { break if page.evaluate_script("window.__probeReady"); sleep 1 }
    assert page.evaluate_script("window.__probeReady"), "the VAD bundle never loaded"

    find("button[aria-label='Start recording']").click
    assert_selector "button[aria-label='Stop recording']", wait: 30

    # Chrome's --use-fake-device-for-media-capture feeds a tone: not speech (so
    # onSpeechEnd stays quiet) but very much signal.
    frames = nil
    5.times do
      frames = JSON.parse(page.evaluate_script("JSON.stringify(window.__frames)"))
      break if frames["count"].to_i.positive? && frames["peak"].to_f.positive?

      sleep 1
    end

    assert_operator frames["count"].to_i, :>, 0,
                    "the VAD processed no audio frames at all — it is being fed a dead stream"
    assert_operator frames["peak"].to_f, :>, 0.0,
                    "frames reached the VAD but were pure silence (peak amplitude 0)"
  end

  # The silent-failure fix: recording with nothing detected must say so while it
  # is happening, and must not spend a commit to be told "No audio uploaded".
  test "says so when nothing is being heard, instead of failing at commit" do
    skip_without_microphone
    visit template_playground_path(@template)
    find("button[aria-label='Start recording']").click
    assert_selector "button[aria-label='Stop recording']", wait: 30

    # A tone is not speech, so this recording captures no phrases — exactly the
    # shape of a muted microphone.
    assert_text "Nothing heard yet", wait: 15

    find("button[aria-label='Stop recording']").click

    assert_text "No speech was detected", wait: 15
    # Retry re-commits, which is useless with nothing to commit; the record
    # button itself is the way back.
    assert_no_selector "[data-playground-target='retry']:not(.hidden)"
  end
end
