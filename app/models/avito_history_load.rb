# One "Load history" run of an Avito account (AvitoChannel::History): where its walk has got to and what it
# imported. The rows stay as the account's record of its loads; the admin page shows the latest. At most one
# per account runs (finished_at nil), which a unique partial index holds even against two starts at once.
class AvitoHistoryLoad < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord
  def running?
    finished_at.nil?
  end

  # The walk's place and counts, as AvitoChannel::History::Batch reads and returns them.
  def position
    { 'since' => since.to_i, 'started_at' => created_at.to_i, 'phase' => phase, 'offset' => list_offset,
      'chat' => chat_id, 'page' => message_offset, 'chats' => chats, 'imported' => imported,
      'unavailable' => unavailable }
  end

  # Saves where a batch got to. The time is set whether or not anything moved: it is what tells a load that
  # still runs from one that died (AvitoChannel::History::STALE).
  def advance!(position)
    update!(phase: position['phase'], list_offset: position['offset'], chat_id: position['chat'],
            message_offset: position['page'], chats: position['chats'], imported: position['imported'],
            unavailable: position['unavailable'], updated_at: Time.zone.now)
  end

  def finish!(error: nil)
    update!(finished_at: Time.zone.now, error: error&.to_s&.truncate(500))
  end

  # What the admin page shows.
  def as_json(*)
    { 'id' => id, 'days' => days, 'phase' => phase, 'chats' => chats, 'imported' => imported,
      'unavailable' => unavailable, 'started_at' => created_at.iso8601, 'finished_at' => finished_at&.iso8601,
      'error' => error }
  end
end
