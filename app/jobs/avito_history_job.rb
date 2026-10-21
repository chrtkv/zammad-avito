# One batch of an account's history load; queues the next one, spaced out (see AvitoChannel::History).
class AvitoHistoryJob < ApplicationJob
  include AvitoChannel::JobRetry

  MAX_ATTEMPTS = 4

  def perform(channel_id, state)
    channel = Channel.find_by(id: channel_id, area: AvitoChannel::AREA)
    return if !channel || !AvitoChannel::History.current?(channel, state)

    if !channel.active
      AvitoChannel::History.finish!(channel, state, error: AvitoChannel.translate(__('The Avito account is disabled.')))
      return
    end

    state, wait = AvitoChannel::History.step(channel, state)
    return if state['finished_at']

    self.class.set(wait: wait.seconds).perform_later(channel.id, state)
  rescue => e
    return retry_later(e, base: 120) if retries_left?(MAX_ATTEMPTS)

    AvitoChannel::History.finish!(channel, state, error: e.message) if channel
  end
end
