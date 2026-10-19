require 'set'

module AvitoMessenger
  # What the reconciliation poll reads and imports. Pure decisions: the caller does the HTTP and the Zammad
  # work. The cursor is the largest chat `updated` (Unix seconds) already handled.
  #
  # Both lists stop at offset 1000, so only the latest ~1100 chats, and ~1100 messages per chat, are reachable.
  module Reconciler
    module_function

    # Chats changed since the cursor, oldest change first: a failure part-way then leaves the cursor at the
    # last chat finished. `>=` re-reads chats sharing the cursor's second, which is safe because imports are
    # idempotent by message id.
    def chats_to_sync(chats, cursor:)
      chats
        .select { |chat| cursor.nil? || updated(chat) >= cursor }
        .uniq { |chat| chat['id'] }
        .sort_by { |chat| [updated(chat), chat['id'].to_s] }
    end

    # Whether the next page of the chat list may still hold chats changed since the cursor. The order of the
    # list is not documented; this stops early only when a whole page is older than the cursor.
    def more_chats?(page, cursor:, offset:, limit: Client::PAGE_LIMIT)
      return false if page.size < limit
      return false if offset + limit > Client::MAX_OFFSET

      cursor.nil? || page.any? { |chat| updated(chat) >= cursor }
    end

    # Messages not imported yet, in the order they were written.
    def missing_messages(messages, known_ids:)
      known = known_ids.to_set
      messages
        .reject { |message| known.include?(message.id) }
        .uniq(&:id)
        .sort_by { |message| [message.created_at || Time.at(0).utc, message.id] }
    end

    # Whether to read an older page of one chat (pages come newest first). Stop at the first message already
    # imported, or older than `since` (the backfill horizon of a newly connected account).
    def more_messages?(page, known_ids:, offset:, since: nil, limit: Client::PAGE_LIMIT)
      return false if page.size < limit
      return false if offset + limit > Client::MAX_OFFSET
      return false if page.any? { |message| known_ids.include?(message.id) }
      return false if since && page.any? { |message| message.created_at && message.created_at < since }

      true
    end

    def updated(chat)
      Message.integer(chat['updated']) || 0
    end
  end
end
