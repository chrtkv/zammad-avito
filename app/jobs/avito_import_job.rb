# Imports one message the Avito webhook delivered. Own messages arrive here a minute late
# (AvitoChannel::OWN_MESSAGE_DELAY) so the echo of a Zammad reply is recognised as such.
class AvitoImportJob < ApplicationJob
  retry_on StandardError, attempts: 4, wait: lambda { |executions|
    executions * 60.seconds
  }

  def perform(channel_id, value)
    channel = Channel.find_by(id: channel_id, area: AvitoChannel::AREA)
    return if !channel&.active

    message = AvitoMessenger::Message.from_hash(value)
    return if message.account_user_id.to_s != channel.options[:user_id].to_s

    AvitoChannel::Importer.new(channel).import(message)
  end
end
