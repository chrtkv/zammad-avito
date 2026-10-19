module AvitoChannel
  # The reconciliation poll of one account: reads the chats changed since the last run and imports whatever
  # the webhook did not deliver, including messages written in Avito itself. Run by Channel::Driver::Avito
  # from Zammad's "Check channels" scheduler.
  #
  # The cursor (channel.preferences[:avito_cursor]) is the latest chat `updated` handled. On the first run it
  # starts at "now" unless the account asks for a backfill (options[:sync][:backfill_days]).
  class Sync
    # Messages older than the cursor by more than this are history from before the account was connected,
    # or were imported already.
    CLOCK_SLACK = 5.minutes

    attr_reader :channel

    def initialize(channel, client: nil, transport: AvitoMessenger::Transport.new, now: Time.zone.now)
      @channel  = channel
      @client   = client || AvitoChannel.client(channel, transport:)
      @importer = Importer.new(channel, client: @client, transport:)
      @now      = now
    end

    # { chats:, imported: }
    def run
      cursor = channel.preferences[:avito_cursor]
      since  = cursor ? Time.zone.at(cursor) - CLOCK_SLACK : backfill_since

      if since.nil?
        save_cursor(horizon.to_i)
        return { chats: 0, imported: 0 }
      end

      chats    = changed_chats(cursor || since.to_i)
      imported = 0
      chats.each do |chat|
        imported += sync_chat(chat, since)
        save_cursor(AvitoMessenger::Reconciler.updated(chat))
      end

      { chats: chats.size, imported: imported }
    end

    private

    def user_id
      channel.options[:user_id]
    end

    # Own messages are imported a minute late (see AvitoChannel::OWN_MESSAGE_DELAY); chats changed inside that
    # minute wait for the next run, and the cursor does not pass them.
    def horizon
      @now - AvitoChannel::OWN_MESSAGE_DELAY.seconds
    end

    def backfill_since
      days = channel.options.dig(:sync, :backfill_days).to_i
      days.positive? ? @now - days.days : nil
    end

    def changed_chats(cursor)
      chats  = []
      offset = 0
      loop do
        page = @client.chats(user_id, offset:)
        chats.concat(page)
        break if !AvitoMessenger::Reconciler.more_chats?(page, cursor:, offset:)

        offset += AvitoMessenger::Client::PAGE_LIMIT
      end

      AvitoMessenger::Reconciler
        .chats_to_sync(chats, cursor:)
        .select { |chat| AvitoMessenger::Reconciler.updated(chat) <= horizon.to_i }
    end

    def sync_chat(chat, since)
      chat_id = chat['id'].to_s
      known   = AvitoMessageRef.known_ids(channel, chat_id)
      @importer.remember_chat(chat)

      messages = []
      offset   = 0
      loop do
        page = @client.messages(user_id, chat_id, offset:)
        messages.concat(page)
        break if !AvitoMessenger::Reconciler.more_messages?(page, known_ids: known, since:, offset:)

        offset += AvitoMessenger::Client::PAGE_LIMIT
      end

      AvitoMessenger::Reconciler
        .missing_messages(messages, known_ids: known)
        .select { |message| message.created_at.nil? || message.created_at >= since }
        .count { |message| @importer.import(message) }
    end

    def save_cursor(value)
      return if channel.preferences[:avito_cursor].to_i >= value.to_i

      channel.preferences[:avito_cursor] = value.to_i
      channel.save!
    end
  end
end
