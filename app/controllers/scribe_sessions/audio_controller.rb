module ScribeSessions
  # The bytes behind one part of a consultation's recording.
  #
  # Deliberately NOT an Active Storage blob URL. Active Storage's own routes are
  # signed but policy-free and permanent by design — anyone holding the link has
  # the audio, forever, with no account check — which is exactly the case the
  # Rails guide tells you to answer with an authenticated controller. A
  # consultation's audio is the most sensitive thing this application stores, so
  # every single request for it, including each seek, passes the same Pundit
  # check that guards the page it plays on.
  #
  # Streamed rather than redirected for the same reason: no presigned URL is
  # ever minted, so the audio has no life outside a signed-in session, and the
  # media stays on this origin (the CSP allows media from :self only). Range
  # requests are answered because that is what seeking is made of — a player
  # jumping to the middle of a 20MB file must not have to pull the first 19.
  # This mirrors ActiveStorage::Blobs::ProxyController, with authorization in
  # front of it.
  #
  # ActionController::Live (via ActiveStorage::Streaming) runs the action on its
  # own thread, which is why this is a controller of its own rather than another
  # action on ScribeSessionsController: nothing else should pay that cost.
  class AudioController < ApplicationController
    include ActiveStorage::Streaming

    # Long enough that seeking backwards and crossing a segment boundary reuse
    # what the browser already has; private and short so clinical audio is not
    # left sitting in a shared cache or on disk for the rest of the day.
    CACHE_CONTROL = "private, max-age=300"

    # GET /scribe_sessions/:scribe_session_id/audio/:source/:source_id
    def show
      session = ScribeSession.find(params[:scribe_session_id])
      authorize session, :show?

      blob = audio_blob(session)
      return head :not_found if blob.nil?

      response.headers["Cache-Control"] = CACHE_CONTROL

      # Disposition is Active Storage's to decide, not the caller's: audio is not
      # on its inline allowlist, so it serves as an attachment whatever is asked
      # for here. That is left alone — a media element ignores the header
      # entirely, so playback is unaffected, and the download link gets the
      # right behaviour and the right filename for free.
      if request.headers["Range"].present?
        send_blob_byte_range_data blob, request.headers["Range"]
      else
        response.headers["Accept-Ranges"] = "bytes"
        response.headers["Content-Length"] = blob.byte_size.to_s
        send_blob_stream blob
      end
    end

    private

    # Scoped through the session in both branches, so an id belonging to someone
    # else's consultation is a 404 rather than a leak — the authorization above
    # is checked against the session the caller named, and this makes sure the
    # blob really hangs off that same session.
    def audio_blob(session)
      case params[:source]
      when "file"    then session.audio_files_attachments.find_by(id: params[:source_id])&.blob
      when "segment" then session.transcript_segments.find_by(id: params[:source_id])&.data&.blob
      end
    end
  end
end
