# Structurally valid PDFs built with correct xref offsets, so pdf-reader parses
# them. Shared by the API integration suite (uploads through Rack::Test) and
# the browser system suite (files on disk for a real file dialog).
module PdfFixtures
  # `declared` overrides the /Count entry independently of how many page
  # objects actually exist, which is how a hostile file understates its size.
  def minimal_pdf(pages: 1, declared: nil)
    kids = (0...pages).map { |i| "#{3 + i} 0 R" }.join(" ")
    objects = []
    objects << "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
    objects << "2 0 obj\n<< /Type /Pages /Kids [#{kids}] /Count #{declared || pages} >>\nendobj\n"
    pages.times do |i|
      objects << "#{3 + i} 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"
    end

    header = "%PDF-1.4\n"
    body = +""
    offsets = []
    objects.each do |obj|
      offsets << (header.bytesize + body.bytesize)
      body << obj
    end
    xref_pos = header.bytesize + body.bytesize
    xref = +"xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { |offset| xref << format("%010d 00000 n \n", offset) }
    trailer = "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"
    header + body + xref + trailer
  end
end
