# One batch of an account's history load; queues the next one, spaced out (see AvitoChannel::History).
class AvitoHistoryJob < ApplicationJob
  include AvitoChannel::JobRetry

  MAX_ATTEMPTS = 4

  def perform(history_load_id)
    history_load = AvitoHistoryLoad.find_by(id: history_load_id)
    return if !history_load&.running?

    channel = Channel.find_by(id: history_load.channel_id, area: AvitoChannel::AREA)
    if !channel&.active
      history_load.finish!(error: AvitoChannel.translate(__('The Avito account is disabled.')))
      return
    end

    wait = AvitoChannel::History.step(channel, history_load)
    return if !history_load.running?

    self.class.set(wait: wait.seconds).perform_later(history_load.id)
  rescue => e
    return retry_later(e, base: 120) if retries_left?(MAX_ATTEMPTS)

    history_load&.finish!(error: e.message)
  end
end
