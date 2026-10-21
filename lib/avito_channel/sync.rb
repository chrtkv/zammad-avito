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
      @transport = transport
      @client    = client || AvitoChannel.client(channel, transport:)
      @importer  = Importer.new(channel, client: @client, transport:)
      @now       = now
      @requests  = 0
    end

    # { chats:, imported:, unavailable: }
    #
    # Every chat changed since the cursor is read in full back to the cursor (less CLOCK_SLACK). Only own
    # messages younger than AvitoChannel::OWN_MESSAGE_DELAY wait for the next run, so the echo of a reply Zammad
    # is sending is recognised; the cursor stops short of the oldest of them, so they and the chat are read
    # again.
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
      @floor      = horizon.to_i
      chats.each do |chat|
        begin
          imported += sync_chat(chat, since)
          @importer.clear_uncovered(chat['id'])
        rescue AvitoMessenger::Error::SubscriptionRequired => e
          unavailable << e
          imported += 1 if @importer.import_uncovered(chat)
        end
        save_cursor([AvitoMessenger::Reconciler.changed_at(chat), @floor].min)
      end
      raise unavailable.first if unavailable.any? && unavailable.size == chats.size

      # Every chat changed up to now has been read: the next run starts here, short of any deferred message.
      save_cursor(@floor)

      { chats: chats.size, imported: imported, unavailable: unavailable.size }
    ensure
      @transport.finish
    end

    # One batch of a history load (AvitoChannel::History): `limit` chats from `offset` of the chat list (newest
    # change first), those changed since `cursor`, each read back to `since`, its messages filed as history
    # (Importer, history: true). The poll's cursor is left alone.
    #
    # The list is read a whole page at a time, as the poll reads it, and the batch is cut out of the page: a
    # page is one request, and batches smaller than a page still reach the last one, at offset 1000.
    #
    # { chats:, imported:, unavailable:, requests:, more: } — `more` when the list may hold further chats
    # changed since the cursor.
    def history(since:, cursor:, offset:, limit:)
      @importer   = Importer.new(channel, client: @client, transport: @transport, history: true)
      @floor      = horizon.to_i
      @requests   = 1
      page_offset = offset - (offset % AvitoMessenger::Client::PAGE_LIMIT)
      page        = @client.chats(user_id, offset: page_offset)
      batch       = page[(offset - page_offset), limit] || []
      chats       = AvitoMessenger::Reconciler.chats_to_sync(batch, cursor:)

      imported    = 0
      unavailable = 0
      chats.each do |chat|
        imported += sync_chat(chat, since)
        @importer.clear_uncovered(chat['id'])
      rescue AvitoMessenger::Error::SubscriptionRequired
        unavailable += 1
        imported += 1 if @importer.import_uncovered(chat)
      end

      # The list is newest change first: a chat older than the cursor ends the walk.
      reached = batch.empty? || batch.any? { |chat| AvitoMessenger::Reconciler.changed_at(chat) < cursor }
      more    = !reached && (offset - page_offset + limit < page.size ||
                             AvitoMessenger::Reconciler.more_chats?(page, cursor:, offset: page_offset))
      { chats: chats.size, imported:, unavailable:, requests: @requests, more: }
    ensure
      @transport.finish
    end

    private

    def user_id
      channel.options[:user_id]
    end

    # Own messages newer than this wait for the next run (see AvitoChannel::OWN_MESSAGE_DELAY).
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

      AvitoMessenger::Reconciler.chats_to_sync(chats, cursor:)
    end

    # Reads the chat back to `since`, whatever it meets on the way: a message the webhook brought says nothing
    # about older ones it may have missed.
    def sync_chat(chat, since)
      chat_id = chat['id'].to_s
      known   = AvitoMessageRef.known_ids(channel, chat_id)
      @importer.remember_chat(chat)

      messages = []
      offset   = 0
      loop do
        page = @client.messages(user_id, chat_id, offset:)
        @requests += 1
        messages.concat(page)
        break if !AvitoMessenger::Reconciler.more_messages?(page, since:, offset:)

        offset += AvitoMessenger::Client::PAGE_LIMIT
      end

      AvitoMessenger::Reconciler
        .missing_messages(messages, known_ids: known)
        .select { |message| message.created_at.nil? || message.created_at >= since }
        .reject { |message| defer?(message) }
        .count { |message| @importer.import(message) }
    end

    def defer?(message)
      return false if !message.own? || message.created_at.nil? || message.created_at <= horizon

      @floor = [@floor, message.created_at.to_i - 1].min
      true
    end

    def save_cursor(value)
      return if channel.preferences[:avito_cursor].to_i >= value.to_i

      channel.preferences[:avito_cursor] = value.to_i
      channel.save!
    end
  end
end
