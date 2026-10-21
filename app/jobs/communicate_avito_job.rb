# Sends an agent's Avito reply. Delivery status and the final "unable to send" note follow Zammad's
# CommunicateTelegramJob; retries go through AvitoChannel::JobRetry.
class CommunicateAvitoJob < ApplicationJob
  include AvitoChannel::JobRetry

  MAX_RETRIES = 4

  def perform(article_id)
    article = Ticket::Article.find(article_id)
    article.preferences['delivery_retry'] = article.preferences['delivery_retry'].to_i + 1
    article.save!

    begin
      AvitoChannel::Delivery.new(article).deliver!
    rescue AvitoChannel::Delivery::Undeliverable => e
      # Retrying cannot help: report it at once.
      fail!(article, e.message, final: true)
      return
    rescue => e
      final = !retries_left?(MAX_RETRIES)
      fail!(article, e.message, final:)
      retry_later(e, base: 120) if !final
      return
    end

    article.preferences['delivery_status_message'] = nil
    article.preferences['delivery_status']         = 'success'
    article.preferences['delivery_status_date']    = Time.zone.now
    article.save!
  end

  private

  # A reply cut into several Avito messages can fail after some of them went out: the status and the note say
  # how many, so the agent knows the customer has already read part of it.
  def fail!(article, message, final:)
    message = message.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
    article.reload
    message = partial_message(article, message)
    article.preferences['delivery_status'] = 'fail'
    article.preferences['delivery_status_message'] = message
    article.preferences['delivery_status_date']    = Time.zone.now
    article.save!
    Rails.logger.error "Avito article #{article.id} not sent: #{message}"

    return if !final

    Ticket::Article.create!(
      ticket_id:     article.ticket_id,
      content_type:  'text/plain',
      body:          AvitoChannel.translate(__('Unable to send Avito message: %s'), message),
      internal:      true,
      sender:        Ticket::Article::Sender.find_by(name: 'System'),
      type:          Ticket::Article::Type.find_by(name: 'note'),
      preferences:   {
        delivery_article_id_related: article.id,
        delivery_message:            true,
      },
      updated_by_id: 1,
      created_by_id: 1,
    )
  end

  def partial_message(article, message)
    pieces = article.preferences.dig('avito', 'pieces') || []
    sent   = pieces.count { |piece| piece['message_id'].present? }
    return message if sent.zero? || sent == pieces.size

    AvitoChannel.translate(__('Sent %s of %s messages; %s'), sent, pieces.size, message)
  end
end
