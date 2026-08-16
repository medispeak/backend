# Be sure to restart your server when you modify this file.

# Application-wide Content Security Policy. Shipped in REPORT-ONLY mode: the
# browser reports violations (Content-Security-Policy-Report-Only header) but
# does not block anything, so the policy cannot break the Administrate admin UI
# or the importmap/tailwind front-end while we observe real traffic. Flip
# `content_security_policy_report_only` to false to enforce once violations are
# confirmed clean. See the Securing Rails Applications Guide:
# https://guides.rubyonrails.org/security.html#content-security-policy-header
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    policy.img_src     :self, :data, :https
    policy.object_src  :none
    # :wasm_unsafe_eval is required by the template playground: the vendored
    # Silero VAD runs through onnxruntime-web, and WebAssembly.instantiate is
    # blocked under a bare `script_src :self`. It permits compiling WebAssembly
    # and nothing else — substantially narrower than :unsafe_eval, which would
    # also re-open eval() and the Function constructor.
    policy.script_src  :self, :wasm_unsafe_eval
    policy.style_src   :self
    policy.connect_src :self
    policy.base_uri    :self
    policy.frame_ancestors :self
    # policy.report_uri "/csp-violation-report-endpoint"  # wire up if a collector exists
  end

  # Nonce for importmap + any permitted inline script/style. importmap-rails and
  # Rails attach this nonce automatically when a generator is configured.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # Observe violations without breaking pages. Enforcement is intentionally
  # deferred until admin (Administrate) inline styles/scripts are confirmed
  # compatible with a nonce-based policy.
  config.content_security_policy_report_only = true
end
