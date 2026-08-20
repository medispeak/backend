Rails.application.routes.draw do
  devise_for :users

  # Super-admin only. Administrate is deliberately confined to this namespace —
  # every day-to-day surface lives in the first-class UI below. Gated by
  # Admin::ApplicationController on User#admin?.
  namespace :admin do
    resources :users do
      # Starting is an admin power, so it lives here. Stopping cannot — see the
      # top-level :impersonation route below.
      post :impersonate, on: :member
    end
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

  # Outside :admin by necessity: impersonating drops admin?, which locks the
  # admin out of /admin, so the exit has to be reachable without it.
  resource :impersonation, only: [ :destroy ]

  resources :scribe_sessions, only: [ :index, :show ] do
    # One part of the consultation's recording, streamed behind the same policy
    # as the page that plays it. A session's audio is either one stored blob or
    # a clip per speech segment (see AudioPlayback), so the player addresses it
    # a part at a time rather than as a single file.
    get "audio/:source/:source_id", to: "scribe_sessions/audio#show", as: :audio,
        constraints: { source: /file|segment/ }
  end

  # Pages and form fields are authored inside the template builder (nested
  # attributes), so they have no standalone CRUD surface of their own.
  resources :templates do
    # The playground: run a real scribe session against this template from the
    # browser. Only the two operations the v2 API restricts to an account token
    # (create a session, mint a scoped one) live here — the browser does its
    # audio upload, commit and polling directly against /api/v2 with the short
    # -lived `mss_` token these hand back, so the playground exercises the same
    # public API a customer integrates against rather than a private shortcut.
    get  "playground",                            to: "playground#show",           as: :playground
    post "playground/sessions",                   to: "playground#create_session", as: :playground_sessions
    post "playground/sessions/:session_id/token", to: "playground#mint_token",     as: :playground_session_token
    get  "playground/result",                     to: "playground#result",         as: :playground_result
  end

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
          patch :transcript, to: "scribe_sessions#update_transcript"
        end
      end

      get :config, to: "config#show"
      get :usage, to: "usage#show"
    end
  end
end
