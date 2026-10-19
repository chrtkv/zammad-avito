# Hooks the Avito channel into Zammad without touching upstream files.
Rails.application.config.to_prepare do
  Ticket::Article.include Ticket::Article::EnqueueCommunicateAvitoJob
end
