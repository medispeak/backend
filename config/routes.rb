Rails.application.routes.draw do
  namespace :admin do
      resources :users
      resources :templates
      resources :domains
      resources :pages, except: [ :destroy ]
      resources :form_fields

      resources :ai_providers
      resources :ai_models
      resources :model_assignments
      resources :accounts
      resources :usage_events, only: [ :index, :show ]

      # Scribe sessions + all associated data (read-only inspection).
      resources :scribe_sessions, only: [ :index, :show ]
      resources :scribe_outputs, only: [ :index, :show ]
      resources :transcripts, only: [ :index, :show ]
      resources :scribe_transcript_segments, only: [ :index, :show ]
      resources :scribe_audio_chunks, only: [ :index, :show ]

      root to: "users#index"
    end
  devise_for :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  resources :templates, only: [ :index, :show, :new, :create, :edit, :update, :destroy ] do
    resources :pages, only: [ :index, :create, :new ]
  end

  resources :pages, only: [ :show ] do
    resources :form_fields, only: [ :index ]
  end

  resources :form_fields, only: [ :show, :edit, :update, :destroy ]

  authenticated :user do
    root to: "dashboard#show", as: :user_root
  end

  root to: "dashboard#show"

  resources :api_tokens, only: [ :index, :show, :new, :create, :destroy ]

  namespace :api, defaults: { format: :json } do
    namespace :v2 do
      resources :scribe_sessions, only: [ :create, :show, :index ] do
        member do
          post :audio
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
