require 'set'

module AvitoMessenger
  # What the reconciliation poll reads and imports. Pure decisions: the caller does the HTTP and the Zammad
  # work. The cursor is the latest chat change (Unix seconds) already handled, a change being the chat's last
  # message: the list comes sorted by last_message.created, newest first (live API, 2026-10-20), while
  # `updated` also moves on reads and is out of that order.
  #
  # Both lists stop at offset 1000, so only the latest ~1100 chats, and ~1100 messages per chat, are reachable.
  module Reconciler
    module_function

    # Chats changed since the cursor, oldest change first: a failure part-way then leaves the cursor at the
    # last chat finished. `>=` re-reads chats sharing the cursor's second, which is safe because imports are
    # idempotent by message id.
    def chats_to_sync(chats, cursor:)
      chats
        .select { |chat| cursor.nil? || changed_at(chat) >= cursor }
        .uniq { |chat| chat['id'] }
        .sort_by { |chat| [changed_at(chat), chat['id'].to_s] }
    end

    # Whether the next page of the chat list may still hold chats changed since the cursor: not once a whole
    # page is older than it.
    def more_chats?(page, cursor:, offset:, limit: Client::PAGE_LIMIT)
      return false if page.size < limit
      return false if offset + limit > Client::MAX_OFFSET

      cursor.nil? || page.any? { |chat| changed_at(chat) >= cursor }
    end

    # Messages not imported yet, in the order they were written.
    def missing_messages(messages, known_ids:)
      known = known_ids.to_set
      messages
        .reject { |message| known.include?(message.id) }
        .uniq(&:id)
        .sort_by { |message| [message.created_at || Time.at(0).utc, message.id] }
    end

    # Whether to read an older page of one chat (pages come newest first): until a page reaches back past
    # `since`, the last point the poll is sure it read. A message already imported proves nothing about older
    # ones: the webhook may have brought it and missed the ones before.
    def more_messages?(page, since:, offset:, limit: Client::PAGE_LIMIT)
      return false if page.size < limit
      return false if offset + limit > Client::MAX_OFFSET
      return false if since && page.any? { |message| message.created_at && message.created_at < since }

      true
    end

    def changed_at(chat)
      last_message = chat['last_message']
      created = Message.integer(last_message['created']) if last_message.is_a?(Hash)
      created || Message.integer(chat['updated']) || 0
    end
  end
end
