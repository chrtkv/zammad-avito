# "Sync now" on the admin page: one reconciliation poll of the account at once, whatever its poll interval.
# Channel#fetch records the outcome on the channel as the scheduler's polls do.
class AvitoSyncJob < ApplicationJob
  def perform(channel_id)
    channel = Channel.find_by(id: channel_id, area: AvitoChannel::AREA)
    return if !channel&.active

    channel.fetch(true)
  end
end
