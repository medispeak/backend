class TemplatesController < ApplicationController
  # The only sortable columns templates actually has. The index previously
  # offered sort links for :title, :fqdn and :autofill — none of them columns.
  SORT_COLUMNS = %w[name created_at].freeze

  before_action :set_template, only: [ :show, :edit, :update, :destroy ]

  # GET /templates
  def index
    @sort = params[:sort].presence_in(SORT_COLUMNS) || "created_at"
    @direction = sort_direction

    scope = policy_scope(Template).order(@sort => @direction)

    begin
      @pagy, @templates = pagy(scope)
    rescue Pagy::VariableError
      # A stale bookmark or a hand-edited ?page= (past the last page, zero,
      # negative, non-numeric) is a bad URL, not a 500. Pagy raises
      # OverflowError / VariableError for all of those; fall back to page one.
      @pagy, @templates = pagy(scope, page: 1)
    end

    # Page and field counts for the listed rows only: two grouped queries
    # instead of an N+1 per template.
    template_ids = @templates.map(&:id)
    @page_counts = Page.where(template_id: template_ids).group(:template_id).count
    @field_counts = FormField.joins(:page)
                             .where(pages: { template_id: template_ids })
                             .group("pages.template_id").count
  end

  # GET /templates/1
  def show
    # Ordered explicitly: a template's pages are a sequence (History, then
    # Examination…) and an unordered select returns them in whatever physical
    # order Postgres happens to hold, which changes after an edit. Loaded up
    # front so the view's `size` does not add a COUNT round trip.
    @pages = @template.pages.includes(:form_fields).order(:id).load
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
    template_id = @template.id
    page_ids = @template.pages.pluck(:id)
    @template.destroy
    # ModelAssignment addresses its scope by (scope_type, scope_id) rather than
    # by association, so nothing cascades: clear this template's rows here — and
    # its pages' rows too, since the pages are destroyed along with it.
    ModelAssignment.where(scope_type: "Template", scope_id: template_id).delete_all
    ModelAssignment.where(scope_type: "Page", scope_id: page_ids).delete_all if page_ids.any?
    redirect_to templates_path, notice: "Template deleted.", status: :see_other
  end

  private

  def set_template
    @template = Template.find(params[:id])
    authorize @template
  rescue ActiveRecord::RecordNotFound
    redirect_to templates_path, alert: "That template no longer exists."
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
