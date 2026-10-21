# One batch of an account's history load; queues the next one, spaced out (see AvitoChannel::History).
class AvitoHistoryJob < ApplicationJob
  MAX_ATTEMPTS = 4

  retry_on StandardError, attempts: MAX_ATTEMPTS, wait: lambda { |executions|
    executions * 120.seconds
  } do |job, error|
    channel = Channel.find_by(id: job.arguments.first, area: AvitoChannel::AREA)
    AvitoChannel::History.finish!(channel, job.arguments.second, error: error.message) if channel
  end

  def perform(channel_id, state)
    channel = Channel.find_by(id: channel_id, area: AvitoChannel::AREA)
    return if !channel || !AvitoChannel::History.current?(channel, state)

    if !channel.active
      locale = Setting.get('locale_default') || 'en-us'
      AvitoChannel::History.finish!(channel, state, error: Translation.translate(locale, __('The Avito account is disabled.')))
      return
    end

    state, wait = AvitoChannel::History.step(channel, state)
    return if state['finished_at']

    self.class.set(wait: wait.seconds).perform_later(channel.id, state)
  rescue AvitoMessenger::Error::RateLimited => e
    raise if executions >= MAX_ATTEMPTS

    # retry_on's wait knows only the attempt number; Avito says how long to wait.
    retry_job(wait: e.retry_after.seconds)
  end
end
