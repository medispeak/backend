class Api::V1::TemplatesController < Api::BaseController
  # GET /api/v1/template/:id
  def show
    @template = Template.active.includes(pages: :form_fields).find_by(id: params[:id])
    if @template
      render "templates/show"
    else
      raise GenericException.new(message: "Template not found", code: :not_found)
    end
  end

  # GET /api/v1/template/find_by_domain/
  def find_by_domain
    origin = find_host(request)
    domain = Domain.find_by(fqdn: origin)
    @template = Template.active.includes(pages: :form_fields).find_by(id: domain&.template_id)

    if @template
      render "templates/show"
    else
      raise GenericException.new(message: "Template not found for the given domain: #{origin}", code: :not_found)
    end
  end

  private

  def find_host(request)
    extract_host(request.origin) || extract_host(request.original_url)
  end

  def extract_host(url)
    url&.match(%r{https?://([^/]+)}).captures[0] rescue nil
  end
end
