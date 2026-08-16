require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module MedispeakBackend
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Do not analyze audio blobs. Active Storage attaches an AudioAnalyzer to
    # every audio/* blob, which enqueues a background job that downloads the
    # blob from S3 and shells out to ffprobe just to read a duration. Production
    # runs on the DO ruby buildpack, which ships NO ffprobe (verified: 0 of 334
    # audio blobs in prod carry a "duration"), so that job can only ever fail —
    # one wasted job and one wasted S3 GET for every segment uploaded, competing
    # with live transcription for the worker's three threads.
    #
    # Nothing reads blob.metadata["duration"] except Scribe::AudioDuration, which
    # measures the audio itself from bytes it already holds. Dropping the
    # analyzer falls audio blobs through to Active Storage's NullAnalyzer, whose
    # `analyze_later? == false` means one inline metadata UPDATE and no job at
    # all. Applied in every environment deliberately: dev/test machines that DO
    # have ffprobe installed would otherwise mask this behaviour (they did).
    #
    # Image analysis is left alone — it is a different analyzer on a different
    # (document/OCR) path.
    config.after_initialize do |app|
      app.config.active_storage.analyzers.delete(ActiveStorage::Analyzer::AudioAnalyzer)
      ActiveStorage.analyzers.delete(ActiveStorage::Analyzer::AudioAnalyzer)
    end
  end
end
