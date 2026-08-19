Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # The public site (Phase 4) — everything below is unauthenticated, served
  # by PublicController subclasses. Phase 6's admin lives elsewhere and is
  # untouched by this file.
  root "home#index"

  get "senate", to: "races#senate"
  get "house", to: "races#house"
  get "races/:slug", to: "races#show", as: :race

  get "dispatches", to: "dispatches#index"
  # Every published piece gets a public permalink — an autonomous newsroom
  # whose output can't be linked to is a newsroom nobody can cite. Retracted
  # dispatches 404 here (the controller scopes to .published), which is what
  # the admin retract button promises.
  get "dispatches/:id", to: "dispatches#show", as: :dispatch

  # Phase 9. Every pollster in the corpus, its estimated lean, and whether the
  # model is acting on it. An adjustment readers cannot inspect is the secret
  # sauce this project promised not to have.
  get "pollsters", to: "pollsters#index"

  get "methodology", to: "pages#methodology"
  get "about", to: "pages#about"
  get "privacy", to: "pages#privacy"

  resource :subscription, only: :create
  get "email-preferences", to: "subscription_preferences#show", as: :email_preferences
  post "email-preferences", to: "subscription_preferences#create"
  get "unsubscribe/:token", to: "unsubscribes#show", as: :unsubscribe
  post "unsubscribe/:token", to: "unsubscribes#create"
  post "webhooks/resend", to: "resend_webhooks#create", as: :resend_webhook

  # Phase 6: the editor's cockpit. Every controller under this namespace
  # inherits Admin::BaseController < ApplicationController and does NOT call
  # allow_unauthenticated_access, so Authentication's default
  # before_action :require_authentication stays in force — see
  # app/controllers/admin/base_controller.rb.
  namespace :admin do
    root to: "dashboard#index"

    resources :polls
    resources :poll_imports, only: [ :new, :create ]

    resources :scrape_runs, only: [ :index, :create ]
    resources :model_runs, only: [ :index, :show, :create ]

    resources :dispatches, only: [ :index, :show, :edit, :update ] do
      member { post :retract }
    end

    resources :newsroom_skips, only: [ :index ]

    resources :races, only: [ :index, :edit, :update ] do
      resources :candidates, only: [ :create, :update, :destroy ]
    end

    resource :settings, only: [ :show, :update ]

    # Gated by the SAME session cookie as the rest of /admin — see the
    # ActiveSupport.on_load(:good_job_application_controller) hook in
    # config/initializers/good_job.rb for how.
    mount GoodJob::Engine => "good_job"
  end
end
