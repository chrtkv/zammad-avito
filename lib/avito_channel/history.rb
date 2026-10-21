module AvitoChannel
  # "Load history" on the admin page: the chats of an account's past days, imported after it was connected
  # (backfill_days applies to the first poll only). Sync#history does the reading; this walks it down the chat
  # list in batches.
  #
  # Avito throttles an address that sends about a hundred requests in a few minutes (docs/DESIGN.md), so each
  # batch of BATCH chats is a job of its own, and the next one waits PACE seconds for every request the last
  # one made: no worker is held, and the load stays well below that rate. Only the latest ~1100 chats of an
  # account, and ~1100 messages of each, can be read at all (offset 1000 is the API's limit).
  #
  # A chat that gets a message while the load runs moves to the top of the list, past the walk; a last sweep
  # reads the chats changed since the load started.
  #
  # Progress is kept in the cache, not on the channel: a poll saves the channel's preferences as it read them
  # when it began, and would put back an older progress. The jobs carry the whole state, so a lost cache entry
  # costs only what the admin page shows.
  module History
    class Invalid < StandardError; end

    BATCH    = 20
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

    # Reads one batch. Returns the next state and the seconds to wait before it, or a finished state.
    def self.step(channel, state, transport: AvitoMessenger::Transport.new)
      sweep  = state['phase'] == 'sweep'
      result = Sync.new(channel, transport:).history(
        since:  Time.zone.at(state['since']),
        cursor: sweep ? state['started_at'] : state['since'],
        offset: state['offset'],
        limit:  BATCH,
      )

      state = state.merge(
        'chats'       => state['chats'] + result[:chats],
        'imported'    => state['imported'] + result[:imported],
        'unavailable' => state['unavailable'] + result[:unavailable],
      )
      if result[:more]
        state['offset'] += BATCH
      elsif !sweep
        state['phase']  = 'sweep'
        state['offset'] = 0
      else
        state['finished_at'] = Time.zone.now.to_i
      end
      store(channel, state)

      [state, result[:requests] * PACE]
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
  end
end
