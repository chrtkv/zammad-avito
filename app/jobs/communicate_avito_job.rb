# Sends an agent's Avito reply. Delivery status, retries and the final "unable to send" note follow
# Zammad's CommunicateTelegramJob.
class CommunicateAvitoJob < ApplicationJob
  MAX_RETRIES = 4

  retry_on StandardError, attempts: MAX_RETRIES, wait: lambda { |executions|
    executions * 120.seconds
  }

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
    rescue AvitoMessenger::Error::RateLimited => e
      final = article.preferences['delivery_retry'] >= MAX_RETRIES
      fail!(article, e.message, final:)
      raise if final

      # retry_on's wait knows only the attempt number; Avito says how long to wait.
      retry_job(wait: e.retry_after.seconds)
      return
    rescue => e
      fail!(article, e.message, final: article.preferences['delivery_retry'] >= MAX_RETRIES)
      raise
    end

    article.preferences['delivery_status_message'] = nil
    article.preferences['delivery_status']         = 'success'
    article.preferences['delivery_status_date']    = Time.zone.now
    article.save!
  end

  private

  def fail!(article, message, final:)
    message = message.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
    article.reload.preferences['delivery_status'] = 'fail'
    article.preferences['delivery_status_message'] = message
    article.preferences['delivery_status_date']    = Time.zone.now
    article.save!
    Rails.logger.error "Avito article #{article.id} not sent: #{message}"

    return if !final

    Ticket::Article.create!(
      ticket_id:     article.ticket_id,
      content_type:  'text/plain',
      body:          "Unable to send Avito message: #{message}",
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
end
