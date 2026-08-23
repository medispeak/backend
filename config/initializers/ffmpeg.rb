# Point Active Storage's analyzers at the vendored static ffmpeg/ffprobe when
# present (production installs them via the app-spec build command). With
# ffprobe available, AnalyzeJob records blob duration metadata, which
# Scribe::AudioDuration prefers over its byte-rate estimate — exact per-minute
# ASR billing instead of an approximation.
{ ffprobe: "ffprobe", ffmpeg: "ffmpeg" }.each do |key, bin|
  path = Rails.root.join("vendor/ffmpeg", bin)
  Rails.application.config.active_storage.paths[key] = path.to_s if File.executable?(path)
end
