class Api::V1::TranscriptionsController < Api::BaseController
  include OpenaiHelper
  include Pagy::Backend

  # POST /api/v1/pages/:page_id/transcriptions
  def create
    page = Page.find_by(id: params[:page_id])
    if page
      begin
        transcription = page.transcriptions.create!(transcription_params.merge(user: current_user))
        text = ai_transcribe(params[:transcription][:audio_file])
        transcription.update!(transcription_text: text, status: :transcribed)
      rescue StandardError => e
        Rails.logger.error("Error during transcription processing: #{e.message}")
        transcription.update!(status: :failed)
        render json: { error: "Internal server error occurred while processing transcription" }, status: :internal_server_error
      else
        render json: format_transcription(transcription), status: :created
      end
    else
      render json: { error: "Page not found" }, status: :not_found
    end
  end

  # GET /api/v1/transcriptions/:id
  def show
    transcription = current_user.transcriptions.find_by(id: params[:id])
    if transcription
      render json: format_transcription(transcription)
    else
      render json: { error: "transcription not found" }, status: :not_found
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
      begin
        ai_generate_completion(transcription)
      rescue StandardError => e
        Rails.logger.error("Error during transcription processing: #{e.message}")
        transcription.update!(status: :failed)
        render json: { error: "Internal server error occurred while processing transcription" }, status: :internal_server_error
      else
          render json: format_transcription(transcription)
      end
    else
      render json: { error: "transcription not found" }, status: :not_found
    end
  end

  def transcription_params
    params.require(:transcription).permit(:audio_file, :duration, :context)
  end

  def format_transcription(transcription)
    transcription.attributes.merge(
      transcription_text: transcription.transcription_text.nil? ? "" : transcription.transcription_text,
      audio_file_url: transcription.audio_file.attached? ? url_for(transcription.audio_file) : nil,
      title: "Transcription #{transcription.id}"
    )
  end
end
