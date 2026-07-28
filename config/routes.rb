Rails.application.routes.draw do
  devise_for :users

  # Super-admin only. Administrate is deliberately confined to this namespace —
  # every day-to-day surface lives in the first-class UI below. Gated by
  # Admin::ApplicationController on User#admin?.
  namespace :admin do
    resources :users
    resources :accounts
    resources :templates
    resources :pages, except: [ :destroy ]
    resources :form_fields
    resources :domains

    resources :ai_providers
    resources :ai_models
    resources :model_assignments
    resources :usage_limits
    resources :usage_events, only: [ :index, :show ]

    # Scribe sessions + associated data (read-only inspection).
    resources :scribe_sessions, only: [ :index, :show ]
    resources :scribe_outputs, only: [ :index, :show ]
    resources :transcripts, only: [ :index, :show ]
    resources :scribe_transcript_segments, only: [ :index, :show ]
    resources :scribe_audio_chunks, only: [ :index, :show ]

    root to: "accounts#index"
  end

  # ---------------------------------------------------------------------------
  # Application UI
  # ---------------------------------------------------------------------------
  resources :scribe_sessions, only: [ :index, :show ]

  # Pages and form fields are authored inside the template builder (nested
  # attributes), so they have no standalone CRUD surface of their own.
  resources :templates

  resource :usage, only: [ :show ], controller: "usage"

  resource :account, only: [ :show, :edit, :update ], controller: "accounts" do
    resources :usage_limits, only: [ :create, :destroy ]
  end

  resources :api_tokens, only: [ :index, :show, :new, :create, :destroy ]

  # Reveal health status on /up that returns 200 if the app boots with no
  # exceptions, otherwise 500. Used by load balancers and uptime monitors.
  get "up" => "rails/health#show", as: :rails_health_check

  authenticated :user do
    root to: "dashboard#show", as: :user_root
  end
  root to: "dashboard#show"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------
  namespace :api, defaults: { format: :json } do
    namespace :v2 do
      resources :scribe_sessions, only: [ :create, :show, :index ] do
        member do
          post :audio
          post :documents
          post :commit
          post :tokens
          post "audio/chunks", to: "scribe_sessions#audio_chunks"
          post "audio/segments", to: "scribe_sessions#audio_segments"
          get "audio/status", to: "scribe_sessions#audio_status"
        end
      end

      get :config, to: "config#show"
      get :usage, to: "usage#show"
    end
  end
end
