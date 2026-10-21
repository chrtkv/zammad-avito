# Imports one message the Avito webhook delivered. Own messages arrive here a minute late
# (AvitoChannel::OWN_MESSAGE_DELAY) so the echo of a Zammad reply is recognised as such.
class AvitoImportJob < ApplicationJob
  include AvitoChannel::JobRetry

  MAX_ATTEMPTS = 4

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
  rescue => e
    return retry_later(e, base: 60) if retries_left?(MAX_ATTEMPTS)

    # The poll reads the chat again and imports what this job could not.
    Rails.logger.error "Avito message #{value.is_a?(Hash) ? value['id'] : '?'} of channel #{channel_id} not imported: #{e.message}"
  end
end
