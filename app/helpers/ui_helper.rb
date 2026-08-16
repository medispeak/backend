# Presentation helpers shared across the application UI.
#
# Status colour is information: one hue per pipeline state, used identically on
# every surface, so a clinician learns the vocabulary once.
module UiHelper
  SESSION_BADGE = {
    "completed" => "badge-success",
    "partial" => "badge-partial",
    "failed" => "badge-failed",
    "processing" => "badge-progress",
    "uploading" => "badge-progress",
    "created" => "badge-neutral",
    "expired" => "badge-neutral"
  }.freeze

  OUTPUT_BADGE = {
    "success" => "badge-success",
    "partial" => "badge-partial",
    "failure" => "badge-failed",
    "pending" => "badge-neutral"
  }.freeze

  # What each metered capability is called in the interface. Defined once so a
  # consultation's usage table and the Usage report never disagree about what
  # the same event is called.
  CAPABILITY_LABELS = {
    "asr" => "Transcription",
    "structuring" => "Structuring",
    "ocr" => "Document OCR"
  }.freeze

  def capability_name(function)
    CAPABILITY_LABELS.fetch(function.to_s, function.to_s.humanize)
  end

  def status_badge(status, kind: :session)
    map = kind == :output ? OUTPUT_BADGE : SESSION_BADGE
    tag.span(status.to_s.humanize, class: "badge #{map.fetch(status.to_s, 'badge-neutral')}")
  end

  # Costs are shown to the cent for totals and to six places on a single event,
  # because a single provider call can legitimately cost a fraction of a cent.
  def format_cost(amount, precision: 2)
    number_to_currency(amount.to_f, unit: "$", precision: precision)
  end

  def format_duration(seconds)
    seconds = seconds.to_i
    return "—" if seconds.zero?

    minutes, secs = seconds.divmod(60)
    minutes.positive? ? "#{minutes}m #{secs}s" : "#{secs}s"
  end

  def format_tokens(count)
    number_with_delimiter(count.to_i)
  end

  # Provider round-trip time. Sub-second reads in milliseconds because that is
  # the resolution that distinguishes two fast models; past a second the decimal
  # is what matters, not three more digits.
  def format_latency(milliseconds)
    ms = milliseconds.to_i
    return "—" if milliseconds.nil? || ms.zero?

    ms < 1000 ? "#{number_with_delimiter(ms)}ms" : "#{(ms / 1000.0).round(1)}s"
  end

  # A relative time for recent things and an absolute one for old things: "3
  # minutes ago" stops being useful past a day.
  def friendly_time(time)
    return "—" if time.blank?

    time > 24.hours.ago ? "#{time_ago_in_words(time)} ago" : time.strftime("%-d %b %Y, %H:%M")
  end

  def nav_link_classes(active)
    base = "px-3 py-2 rounded-md text-sm font-medium no-underline"
    active ? "#{base} bg-blue-50 text-blue-700" : "#{base} text-gray-700 hover:bg-gray-100 hover:text-gray-900"
  end
end
