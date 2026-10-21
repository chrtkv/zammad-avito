# Which Avito messages are already in Zammad, and in which article. One row per Avito message: an article
# can hold several (a long reply goes out as several Avito messages), so Ticket::Article#message_id alone
# cannot answer "is this message known?". A row outlives a deleted article on purpose: the message must not
# be imported again.
class AvitoMessageRef < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord
  def self.known?(channel, avito_message_id)
    exists?(channel_id: channel.id, avito_message_id: avito_message_id.to_s)
  end

  def self.known_ids(channel, chat_id)
    where(channel_id: channel.id, chat_id: chat_id.to_s).pluck(:avito_message_id)
  end

  # Records the message; false when it was recorded already. The unique index makes this the one place where
  # the webhook and the poll, delivering the same message at once, decide which of them imports it. Call it
  # inside the transaction that creates the article, so the record and the article stand or fall together.
  def self.claim!(channel, chat_id, avito_message_id, article = nil)
    result = insert_all(
      [{ channel_id: channel.id, chat_id: chat_id.to_s, avito_message_id: avito_message_id.to_s,
         ticket_article_id: article&.id, created_at: Time.zone.now }],
      unique_by: %i[channel_id avito_message_id],
      returning: %i[id],
    )
    result.rows.any?
  end

  def self.attach!(channel, avito_message_id, article)
    where(channel_id: channel.id, avito_message_id: avito_message_id.to_s).update_all(ticket_article_id: article.id) # rubocop:disable Rails/SkipsModelValidations
  end
end
