Zammad::Application.routes.draw do
  api_path = Rails.configuration.api_path

  match api_path + '/channels_avito',                         to: 'channels_avito#index',     via: :get
  match api_path + '/channels_avito',                         to: 'channels_avito#add',       via: :post
  match api_path + '/channels_avito/:id',                     to: 'channels_avito#update',    via: :put
  match api_path + '/channels_avito/:id',                     to: 'channels_avito#destroy',   via: :delete
  match api_path + '/channels_avito/:id/subscribe',           to: 'channels_avito#subscribe', via: :post
  match api_path + '/channels_avito/:id/enable',              to: 'channels_avito#enable',    via: :post
  match api_path + '/channels_avito/:id/disable',             to: 'channels_avito#disable',   via: :post
  match api_path + '/channels_avito/:id/check',               to: 'channels_avito#check',     via: :post
  match api_path + '/channels_avito/:id/sync',                to: 'channels_avito#sync',      via: :post
  match api_path + '/channels_avito/:id/history',             to: 'channels_avito#history',   via: :post
  match api_path + '/channels_avito_webhook/:callback_token', to: 'channels_avito#webhook',   via: :post
end
