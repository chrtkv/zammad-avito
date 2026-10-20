module AvitoChannel
  # The reconciliation poll of one account: reads the chats changed since the last run and imports whatever
  # the webhook did not deliver, including messages written in Avito itself. Run by Channel::Driver::Avito
  # from Zammad's "Check channels" scheduler.
  #
  # The cursor (channel.preferences[:avito_cursor]) is the latest chat change handled (see Reconciler). On the first run it
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

    # { chats:, imported:, unavailable: }
    #
    # The subscription can cover some chats and not others (Avito sells it per category of listings): such a
    # chat answers 402. It does not hold up the rest; its latest message, which the chat list carries, is
    # imported and the ticket flagged (Importer#import_uncovered). When every chat answers 402, the error is
    # raised as well, for the channel to show it.
    def run
      cursor = channel.preferences[:avito_cursor]
      since  = cursor ? Time.zone.at(cursor) - CLOCK_SLACK : backfill_since

      if since.nil?
        save_cursor(horizon.to_i)
        return { chats: 0, imported: 0, unavailable: 0 }
      end

      chats       = changed_chats(cursor || since.to_i)
      imported    = 0
      unavailable = []
      chats.each do |chat|
        begin
          imported += sync_chat(chat, since)
          @importer.clear_uncovered(chat['id'])
        rescue AvitoMessenger::Error::SubscriptionRequired => e
          unavailable << e
          imported += 1 if @importer.import_uncovered(chat)
        end
        save_cursor(AvitoMessenger::Reconciler.changed_at(chat))
      end
      raise unavailable.first if unavailable.any? && unavailable.size == chats.size

      { chats: chats.size, imported: imported, unavailable: unavailable.size }
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
        .select { |chat| AvitoMessenger::Reconciler.changed_at(chat) <= horizon.to_i }
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
