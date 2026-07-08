class Api::V1::MeController < Api::BaseController
  def show
    render json: current_user.slice(:id, :email, :account_id)
  end

  def destroy
    current_user.destroy
    render json: {}
  end
end
