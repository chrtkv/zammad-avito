# Imports one message the Avito webhook delivered. Own messages arrive here a minute late
# (AvitoChannel::OWN_MESSAGE_DELAY) so the echo of a Zammad reply is recognised as such.
class AvitoImportJob < ApplicationJob
  MAX_ATTEMPTS = 4

  retry_on StandardError, attempts: MAX_ATTEMPTS, wait: lambda { |executions|
    executions * 60.seconds
  }

  def perform(channel_id, value)
    channel = Channel.find_by(id: channel_id, area: AvitoChannel::AREA)
    return if !channel&.active

    message = AvitoMessenger::Message.from_hash(value)
    return if message.account_user_id.to_s != channel.options[:user_id].to_s

    transport = AvitoMessenger::Transport.new
    begin
      AvitoChannel::Importer.new(channel, transport:).import(message)
    ensure
      transport.finish
    end
  rescue AvitoMessenger::Error::RateLimited => e
    raise if executions >= MAX_ATTEMPTS

    # retry_on's wait knows only the attempt number; Avito says how long to wait.
    retry_job(wait: e.retry_after.seconds)
  end
end
