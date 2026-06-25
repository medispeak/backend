module TemplatesHelper
  # AiModels usable for a given capability (:can_transcribe / :can_structure),
  # formatted for a select: [label, id].
  def ai_model_options(capability)
    AiModel.active.includes(:ai_provider).filter_map do |model|
      next unless model.capability?(capability)

      label = "#{model.display_name.presence || model.api_model_id} · #{model.ai_provider.name}"
      [ label, model.id ]
    end
  end

  # The currently-assigned model id for a Template + function, if any.
  def template_assigned_model_id(template, function)
    return nil unless template&.persisted?

    ModelAssignment.find_by(
      scope_type: "Template", scope_id: template.id, function: function.to_s
    )&.ai_model_id
  end

  def field_type_options
    FormField.field_types.keys.map { |k| [ k.humanize, k ] }
  end
end
