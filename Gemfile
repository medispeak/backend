source "https://rubygems.org"

# Use main development branch of Rails
gem "rails", "~> 8.0"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Load environment variables from .env file
gem "dotenv-rails", "~> 3.1", groups: %i[development test]
# Inline SVG
gem "inline_svg", "~> 1.10.0"
# Administrate for admin panel
gem "administrate", github: "thoughtbot/administrate", branch: "main"
# Open AI ruby
gem "ruby-openai", "~> 6.2"
# Pagy for pagination
gem "pagy", "~> 6.0"
# Pundit for authorization
gem "pundit", "~> 2.4"
# AWS S3 for file storage
gem "aws-sdk-s3", require: false
# Devise for authentication
gem "devise", "~> 4.9"
# Tailwind CSS
gem "tailwindcss-rails", "~> 2.7"
# CORS for API
gem "rack-cors", "~> 2.0.1"
# JSON Schema validation for structured-output validate + repair
gem "json_schemer", "~> 2.3"
# Edge throttling / rate limiting
gem "rack-attack", "~> 6.7"
# Declarative content-type + size validations for Active Storage attachments
gem "active_storage_validations", "~> 1.1"
# PDF page counting at document upload time (OCR modality page caps + metering)
gem "pdf-reader", "~> 2.12"



# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue", "~> 1.1.0"
gem "solid_cable", "~> 3.0.5"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", "~> 2.4.0", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", "~> 0.1.9", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Scan the Ruby gem dependency tree for known CVEs [https://github.com/rubysec/bundler-audit]
  gem "bundler-audit", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
  gem "pry"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # Stub external provider HTTP in adapter/contract tests
  gem "webmock", "~> 3.24"
  # Concise mocking/stubbing for service-object tests
  gem "mocha", "~> 2.7"
  # Test data factories
  gem "factory_bot_rails", "~> 6.4"
end
