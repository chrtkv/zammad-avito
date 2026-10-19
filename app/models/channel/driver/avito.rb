# Polls one Avito account for what the webhook missed. Zammad's "Check channels" scheduler calls fetch for
# every active channel whose area ends in ::Account, so Avito::Account gets here every 30 s; fetchable?
# spaces the polls out to the account's poll interval.
class Channel::Driver::Avito
  def fetchable?(channel)
    last     = channel.preferences[:last_fetch]
    interval = (channel.options.dig(:sync, :poll_interval).presence || AvitoChannel::POLL_INTERVAL).to_i

    last.nil? || last <= interval.seconds.ago
  end

  def fetch(_options, channel)
    result = AvitoChannel::Sync.new(channel).run

    {
      result: 'ok',
      notice: "#{result[:imported]} messages from #{result[:chats]} chats",
    }
  end

  def disconnect; end
end
