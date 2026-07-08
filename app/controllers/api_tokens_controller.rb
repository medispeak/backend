class ApiTokensController < ApplicationController
  before_action :authenticate_user!
  before_action :set_api_token, only: [ :show, :destroy ]

  def index
    @api_tokens = current_user.api_tokens
  end

  def show
  end

  def new
    @api_token = current_user.api_tokens.new
  end

  def create
    @api_token = current_user.api_tokens.new(api_token_params)
    if @api_token.save
      flash[:raw_token] = @api_token.raw_token
      redirect_to @api_token, notice: "API token created. Copy it now — it will not be shown again."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    @api_token.update(active: false)
    redirect_to api_tokens_path, notice: "API token was successfully revoked."
  end

  private

  def set_api_token
    @api_token = current_user.api_tokens.find(params[:id])
  end

  def api_token_params
    params.require(:api_token).permit(:name, :expires_at)
  end
end
