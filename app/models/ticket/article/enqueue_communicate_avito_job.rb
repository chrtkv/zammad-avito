# Sends new Avito articles written in Zammad to the chat. Included into Ticket::Article by
# config/initializers/avito_channel.rb rather than by patching the model.
module Ticket::Article::EnqueueCommunicateAvitoJob
  extend ActiveSupport::Concern

  included do
    after_create_commit :ticket_article_enqueue_communicate_avito_job
  end

  private

  def ticket_article_enqueue_communicate_avito_job
    return true if Setting.get('import_mode')
    return true if internal

    type = Ticket::Article::Type.lookup(id: type_id)
    return true if type&.name != AvitoChannel::ARTICLE_TYPE

    sender = Ticket::Article::Sender.lookup(id: sender_id)
    return true if sender.nil? || sender.name == 'Customer'

    # Imported from Avito: it is there already, whoever wrote it.
    return true if preferences.dig('avito', 'origin') == 'avito'

    CommunicateAvitoJob.perform_later(id)
  end
end
