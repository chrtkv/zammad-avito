module AvitoChannel
  # "Load history" on the admin page: the chats of an account's past days, imported after it was connected
  # (backfill_days applies to the first poll only). It walks down the chat list, newest change first, and
  # reads each chat back to the start date, page by page; its messages are filed as history (Importer,
  # history: true). The poll's cursor is left alone.
  #
  # Avito throttles an address that sends about a hundred requests in a few minutes (docs/DESIGN.md). Each job
  # (AvitoHistoryJob) makes BUDGET requests, every request through the transport counted (plus at most the
  # file of the one message being imported when it ran out), and stops wherever that leaves it: between
  # chats, or within a chat's history, which the next job reads on from the same page. The next job waits PACE
  # seconds for every request the last one made, so the load stays near twenty requests a minute with no
  # burst above about BUDGET, and no worker is held. A batch of whole chats made 141
  # requests in a row on a deep history (review, 2026-10-21). Only the latest ~1100 chats of an account, and
  # ~1100 messages of each, can be read at all (offset 1000 is the API's limit).
  #
  # A chat that gets a message while the load runs moves to the top of the list, past the walk; a last sweep
  # reads the chats changed since the load started. A chat the walk is inside of is followed by its id, not by
  # its place in the list, which such moves shift.
  #
  # Progress is kept in the cache, not on the channel: a poll saves the channel's preferences as it read them
  # when it began, and would put back an older progress. The jobs carry the whole state, so a lost cache entry
  # costs only what the admin page shows. The Docker image's zammad-init clears the cache on every start: a
  # running load reappears with its next job, a finished one's result is gone.
  module History
    class Invalid < StandardError; end

    BUDGET   = 10
    PACE     = 3
    MAX_DAYS = 365
    # A load whose state has not moved for this long is taken to have died, and another may start.
    STALE    = 30.minutes

    # The first state; AvitoHistoryJob takes it from here.
    def self.start!(channel, days:, now: Time.zone.now)
      days = Integer(days.to_s, 10, exception: false)
      raise Invalid, __('Enter a number of days from 1 to 365.') if !days&.between?(1, MAX_DAYS)
      raise Invalid, __('The history of this account is being loaded already.') if running?(channel)

      state = {
        'run'         => SecureRandom.hex(8),
        'days'        => days,
        'since'       => (now - days.days).to_i,
        'started_at'  => now.to_i,
        'phase'       => 'walk',
        'offset'      => 0,
        'chat'        => nil,
        'page'        => 0,
        'chats'       => 0,
        'imported'    => 0,
        'unavailable' => 0,
      }
      store(channel, state)
      AvitoHistoryJob.perform_later(channel.id, state)
      state
    end

    def self.state(channel)
      Rails.cache.read(key(channel))
    end

    def self.running?(channel)
      state = state(channel)
      state.present? && state['finished_at'].nil? && state['updated_at'].to_i > STALE.ago.to_i
    end

    # Whether a job of this run should go on: not once another load has taken its place.
    def self.current?(channel, state)
      stored = state(channel)
      stored.nil? || stored['run'] == state['run']
    end

    # Runs one job's batch. Returns the next state and the seconds to wait before it, or a finished state.
    def self.step(channel, state, transport: AvitoMessenger::Transport.new)
      state, requests, through = Batch.new(channel, state, transport:).run
      if through && state['phase'] == 'walk'
        state = state.merge('phase' => 'sweep', 'offset' => 0, 'chat' => nil, 'page' => 0)
      elsif through
        state = state.merge('finished_at' => Time.zone.now.to_i)
      end
      store(channel, state)

      [state, [requests, 1].max * PACE]
    end

    def self.finish!(channel, state, error:)
      store(channel, state.merge('finished_at' => Time.zone.now.to_i, 'error' => error.to_s))
    end

    def self.store(channel, state)
      Rails.cache.write(key(channel), state.merge('updated_at' => Time.zone.now.to_i), expires_in: 30.days)
    end

    def self.key(channel)
      "avito-history-#{channel.id}"
    end

    private_class_method :store, :key

    # Counts the requests a batch makes, whatever makes them: the chat list, message pages, the files and
    # chats the importer fetches, a token refresh.
    class CountedTransport < SimpleDelegator
      attr_reader :requests

      def initialize(transport)
        super
        @requests = 0
      end

      def call(...)
        @requests += 1
        __getobj__.call(...)
      end
    end

    # One job's part of the walk (see the module's comment).
    class Batch
      def initialize(channel, state, transport:, now: Time.zone.now)
        @channel   = channel
        @state     = state.dup
        @transport = CountedTransport.new(transport)
        @client    = AvitoChannel.client(channel, transport: @transport)
        @importer  = Importer.new(channel, client: @client, transport: @transport, history: true)
        @since     = Time.zone.at(state['since'])
        @cursor    = state['phase'] == 'sweep' ? state['started_at'] : state['since']
        # Own messages younger than this wait for the poll, as there (AvitoChannel::OWN_MESSAGE_DELAY).
        @horizon   = now - AvitoChannel::OWN_MESSAGE_DELAY.seconds
      end

      # [state, requests made, whether the walk (or the sweep) is through]
      def run
        loop do
          if !@state['chat']
            # With the budget spent, the list page at hand can still tell that the walk is through.
            return [@state, @transport.requests, false] if spent? && !page_at_hand?

            chat = upcoming_chat
            return [@state, @transport.requests, true] if !chat
            return [@state, @transport.requests, false] if spent?

            start_chat(chat)
          elsif spent?
            return [@state, @transport.requests, false]
          end

          read_page(@state['chat'])
        end
      ensure
        @transport.finish
      end

      private

      def spent?
        @transport.requests >= BUDGET
      end

      def user_id
        @channel.options[:user_id]
      end

      def page_offset
        @state['offset'] - (@state['offset'] % AvitoMessenger::Client::PAGE_LIMIT)
      end

      def page_at_hand?
        @page_offset == page_offset
      end

      # The chat at the walk's place in the list, or nil once the list holds none changed since the cursor.
      def upcoming_chat
        return nil if page_offset > AvitoMessenger::Client::MAX_OFFSET

        if !page_at_hand?
          @page        = @client.chats(user_id, offset: page_offset)
          @page_offset = page_offset
        end
        chat = @page[@state['offset'] - page_offset]
        return nil if !chat || AvitoMessenger::Reconciler.changed_at(chat) < @cursor

        chat
      end

      def start_chat(chat)
        @importer.remember_chat(chat)
        @chat = chat
        @state.merge!('chat' => chat['id'].to_s, 'page' => 0, 'chats' => @state['chats'] + 1)
      end

      # One page of the chat's messages, newest first. Stopping part-way leaves the page where it is: the next
      # job reads it again and skips what was imported.
      def read_page(chat_id)
        messages = @client.messages(user_id, chat_id, offset: @state['page'])
        # Importing a text costs nothing; an image or a voice message fetches its file, one request.
        stopped = missing(chat_id, messages).find do |message|
          next true if @transport.requests > BUDGET

          @state['imported'] += 1 if @importer.import(message)
          false
        end
        return if stopped

        if AvitoMessenger::Reconciler.more_messages?(messages, since: @since, offset: @state['page'])
          @state['page'] += AvitoMessenger::Client::PAGE_LIMIT
        else
          @importer.clear_uncovered(chat_id)
          next_place
        end
      rescue AvitoMessenger::Error::SubscriptionRequired
        @state['unavailable'] += 1
        @state['imported'] += 1 if @chat && @chat['id'].to_s == chat_id && @importer.import_uncovered(@chat)
        next_place
      end

      def missing(chat_id, messages)
        AvitoMessenger::Reconciler
          .missing_messages(messages, known_ids: AvitoMessageRef.known_ids(@channel, chat_id))
          .select { |message| message.created_at.nil? || message.created_at >= @since }
          .reject { |message| message.own? && message.created_at && message.created_at > @horizon }
      end

      def next_place
        @state.merge!('chat' => nil, 'page' => 0, 'offset' => @state['offset'] + 1)
      end
    end
  end
end
