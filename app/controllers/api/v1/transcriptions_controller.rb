class Api::V1::TranscriptionsController < Api::BaseController
  include OpenaiHelper
  include Pagy::Backend

  # POST /api/v1/pages/:page_id/transcriptions
  def create
    page = Page.find_by(id: params[:page_id])
    raise GenericException.new(message: "Page not found", code: :not_found) unless page

    reject_invalid_audio!(params.dig(:transcription, :audio_file))

    transcription = create_transcription(page)
    render json: format_transcription(transcription), status: :created
  end

  # GET /api/v1/transcriptions/:id
  def show
    transcription = current_user.transcriptions.find_by(id: params[:id])
    if transcription
      render json: format_transcription(transcription)
    else
      raise GenericException.new(message: "Transcription not found", code: :not_found)
    end
  end

  # GET /api/v1/transcriptions
  def index
    # Paginate the transcriptions
    pagy, transcriptions = pagy(current_user.transcriptions.order(created_at: :desc))

    serialized_transcriptions = transcriptions.map do |transcription|
      format_transcription(transcription)
    end

    # Prepare the pagy metadata
    pagy_metadata = {
      page: pagy.page,
      items: pagy.items,
      count: pagy.count,
      page_count: pagy.pages
    }


    # Render the response with transcriptions and pagination metadata
    render json: { transcriptions: serialized_transcriptions, pagy: pagy_metadata }
  end

  # POST /api/v1/transcriptions/:id/generate_completion
  def generate_completion
    transcription = current_user.transcriptions.find_by(id: params[:id])
    if transcription
      ai_generate_completion(transcription)
      render json: format_transcription(transcription)
    else
      raise GenericException.new(message: "Transcription not found", code: :not_found)
    end
  end

  private

  # Reject a non-audio or oversized upload before persisting a Transcription or
  # calling ASR — a denial-of-wallet / storage-abuse guard (plan 014). The
  # declared content-type is a spoofable first-line check; model validation is
  # defense-in-depth.
  def reject_invalid_audio!(upload)
    invalid =
      upload.blank? ||
      !upload.respond_to?(:content_type) ||
      !Transcription::ALLOWED_AUDIO_TYPES.include?(upload.content_type) ||
      upload.size > Transcription::MAX_AUDIO_BYTES

    return unless invalid

    raise GenericException.new(message: "unsupported or oversized audio upload", code: :unprocessable_entity)
  end

  def create_transcription(page)
    transcription = page.transcriptions.create!(transcription_params.merge(user: current_user))
    text = ai_transcribe(params[:transcription][:audio_file], page: page, account: current_user.account)
    transcription.update!(transcription_text: text, status: :transcribed)
    transcription
  rescue Seahorse::Client::NetworkingError => e
    handle_audio_upload_error(e)
  end

  def handle_audio_upload_error(error)
    Rails.logger.error("Error saving audio file for transcription: #{error.message}")
    raise GenericException.new(
      message: "Error saving audio file for transcription: #{error.message}",
      code: :failed_dependency
    )
  end

  def transcription_params
    params.require(:transcription).permit(:audio_file, :duration, :context)
  end

  def format_transcription(transcription)
    transcription.attributes.merge(
      audio_file_url: transcription.audio_file.attached? ? url_for(transcription.audio_file) : nil,
      title: "Transcription #{transcription.id}"
    )
  end
end
