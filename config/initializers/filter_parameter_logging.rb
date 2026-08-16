# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :context, :transcript, :transcription_text, :payload, :results, :note, :form, :audio, :audio_file,
  # The chunked and segmented upload paths carry the same recorded speech as
  # :audio under different param names, so they need the same treatment — an
  # unfiltered :segment writes PHI straight to the Rails log.
  :segment, :chunk
]
