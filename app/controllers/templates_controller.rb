class TemplatesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_template, only: [ :show, :edit, :update, :destroy ]

  after_action :verify_authorized
  rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized

  # GET /templates
  def index
    @pagy, @templates = pagy(policy_scope(Template).sort_by_params(params[:sort], sort_direction))
    authorize @templates
  end

  # GET /templates/1
  def show
  end

  # GET /templates/new
  def new
    @template = Template.new
    @template.pages.build.form_fields.build
    authorize @template
  end

  # POST /templates
  def create
    @template = Template.new(template_params.merge(account: current_user.account))
    authorize @template

    if @template.save
      assign_models(@template)
      redirect_to @template, notice: "Template created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /templates/1/edit
  def edit
  end

  # PATCH/PUT /templates/1
  def update
    if @template.update(template_params)
      assign_models(@template)
      redirect_to @template, notice: "Template updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /templates/1
  def destroy
    @template.destroy
    redirect_to templates_path, notice: "Template deleted."
  end

  private

  def set_template
    @template = Template.find(params[:id])
    authorize @template
  rescue ActiveRecord::RecordNotFound
    redirect_to templates_path
  end

  def template_params
    params.require(:template).permit(
      :name, :description,
      pages_attributes: [
        :id, :name, :prompt, :_destroy,
        form_fields_attributes: [
          :id, :title, :friendly_name, :description, :field_type,
          :minimum, :maximum, :enum_options_raw, :_destroy
        ]
      ]
    )
  end

  # Creates/updates Template-scoped ModelAssignments from the builder's model
  # pickers (resolution order Page -> Template -> Account -> System).
  def assign_models(template)
    { asr: params[:asr_ai_model_id], structuring: params[:structuring_ai_model_id] }.each do |function, ai_model_id|
      next if ai_model_id.blank?

      assignment = ModelAssignment.find_or_initialize_by(
        scope_type: "Template", scope_id: template.id, function: function.to_s
      )
      assignment.ai_model_id = ai_model_id
      assignment.save
    end
  end
end
