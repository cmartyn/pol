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

  get "methodology", to: "pages#methodology"
  get "about", to: "pages#about"
end
