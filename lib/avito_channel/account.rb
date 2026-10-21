module AvitoChannel
  # Connecting, changing and removing Avito accounts. Each account is its own Channel with its own
  # credentials, token, webhook URL and subscription.
  module Account
    class Invalid < StandardError; end

    WEBHOOK_PATH = '/api/v1/channels_avito_webhook'.freeze

    # How stale the "last webhook delivery" time may get: the channel is saved for a delivery only once this
    # has passed since the time it holds, not for every message.
    WEBHOOK_NOTE_INTERVAL = 1.minute

    # params: client_id, client_secret, group_id, backfill_days, poll_interval, mark_read, webhook_base_url.
    # A blank or masked client_secret keeps the stored one. Returns the saved channel.
    def self.save!(params, channel = nil, transport: AvitoMessenger::Transport.new)
      params = params.to_h.with_indifferent_access
      auth   = channel&.options&.dig(:auth) || {}

      client_id = params[:client_id].presence || auth[:client_id]
      secret    = params[:client_secret]
      secret    = auth[:client_secret] if secret.blank? || secret == SensitiveParamsHelper::SENSITIVE_MASK
      raise Invalid, __('Client ID and client secret are required.') if client_id.blank? || secret.blank?

      group_id = params[:group_id].presence || channel&.group_id
      raise Invalid, __('Please choose a group.') if group_id.blank? || !Group.exists?(id: group_id)

      client  = AvitoMessenger::Client.new(client_id:, client_secret: secret, transport:, base_url: AvitoChannel.api_base_url)
      account = fetch_account(client)
      user_id = account['id']
      raise Invalid, __('Avito did not return the account id.') if user_id.blank?
      raise Invalid, __('This Avito account is already connected.') if duplicate?(user_id, channel)
      # The channel's tickets, recorded messages, cursor and webhook belong to its account: other keys would
      # send replies to those chats from a different shop.
      if channel&.persisted? && channel.options[:user_id].present? && channel.options[:user_id].to_s != user_id.to_s
        raise Invalid, __('These keys belong to another Avito account. Connect it as a new account.')
      end

      subscribed_url = channel&.options&.dig(:webhook, :url).presence
      channel ||= Channel.new(area: AREA, active: true)
      channel.group_id = group_id
      channel.options  = {
        adapter:          ADAPTER,
        auth:             {
          client_id:               client_id,
          client_secret:           secret,
          access_token:            client.token.access_token,
          access_token_expires_at: client.token.expires_at.to_i,
        },
        user_id:          user_id,
        name:             account['name'].presence || "Avito #{user_id}",
        callback_token:   channel.options&.dig(:callback_token).presence || SecureRandom.urlsafe_base64(24),
        webhook_base_url: params.key?(:webhook_base_url) ? params[:webhook_base_url].presence : channel.options&.dig(:webhook_base_url),
        mark_read:        params.key?(:mark_read) ? ActiveModel::Type::Boolean.new.cast(params[:mark_read]) != false : channel.options&.dig(:mark_read) != false,
        sync:             {
          backfill_days: integer_param(params, :backfill_days, channel&.options&.dig(:sync, :backfill_days)) || 0,
          poll_interval: integer_param(params, :poll_interval, channel&.options&.dig(:sync, :poll_interval)) || POLL_INTERVAL,
        },
        webhook:          channel.options&.dig(:webhook) || {},
      }
      # A new address is not subscribed until Avito is told: drop the old status, remember the old address
      # for resubscribe_if_moved! to unsubscribe.
      if subscribed_url && subscribed_url != webhook_url(channel)
        channel.options[:webhook] = { 'url' => nil, 'subscribed_at' => nil, 'error' => nil, 'moved_from' => subscribed_url }
      end
      channel.save!
      channel
    end

    def self.by_callback_token(token)
      return nil if token.blank?

      AvitoChannel.channels.find do |channel|
        expected = channel.options[:callback_token].to_s
        expected.present? && ActiveSupport::SecurityUtils.secure_compare(expected, token.to_s)
      end
    end

    def self.webhook_url(channel)
      base = channel.options[:webhook_base_url].presence || "#{Setting.get('http_type')}://#{Setting.get('fqdn')}"
      "#{base.chomp('/')}#{WEBHOOK_PATH}/#{channel.options[:callback_token]}"
    end

    # Registers the channel's webhook URL with Avito. The outcome is kept on the channel for the admin page.
    def self.subscribe!(channel, transport: AvitoMessenger::Transport.new)
      url = webhook_url(channel)
      AvitoChannel.client(channel, transport:).subscribe_webhook(url)
      store_webhook(channel, 'url' => url, 'subscribed_at' => Time.zone.now.iso8601, 'error' => nil)
      true
    rescue AvitoMessenger::Error => e
      store_webhook(channel, 'url' => url, 'subscribed_at' => nil, 'error' => e.message)
      false
    end

    # After save! moved the webhook address: unsubscribe the old one, subscribe the new one.
    def self.resubscribe_if_moved!(channel, transport: AvitoMessenger::Transport.new)
      old_url = channel.options.dig(:webhook, :moved_from)
      return false if old_url.blank?

      unsubscribe(channel, url: old_url, transport:)
      subscribe!(channel, transport:)
    end

    def self.unsubscribe(channel, url: nil, transport: AvitoMessenger::Transport.new)
      url ||= channel.options.dig(:webhook, :url).presence || webhook_url(channel)
      AvitoChannel.client(channel, transport:).unsubscribe_webhook(url)
    rescue AvitoMessenger::Error => e
      Rails.logger.warn "Avito webhook of channel #{channel.id} not removed: #{e.message}"
    end

    def self.destroy!(channel, transport: AvitoMessenger::Transport.new)
      unsubscribe(channel, transport:)
      AvitoMessageRef.where(channel_id: channel.id).delete_all
      channel.destroy!
    end

    # "Check connection" on the admin page: a new token, the account, the latest chat and one of its messages,
    # and the webhook subscriptions Avito holds, in that order; the first failure says what is wrong. Five
    # requests that change nothing. Reading a message matters: Avito can list the chats and still refuse their
    # messages (402) when the subscription does not cover the listing's category (docs/DESIGN.md); a check of
    # the list alone said "ok" then (review, 2026-10-21). Only the latest chat is read, so a chat of another
    # category can still be refused.
    #
    # { 'status' => 'ok' | 'auth' | 'subscription' | 'chat_refused' | 'rate_limited' | 'network' |
    #               'other_account' | 'error',
    #   'message' => Avito's own words,
    #   'account' => name, 'messages_checked' => false when the account has no chat to read,
    #   'subscriptions' => [url], 'subscribed' => whether Avito has this channel's URL }
    def self.check(channel, transport: AvitoMessenger::Transport.new)
      user_id = channel.options[:user_id]
      client  = AvitoChannel.client(channel, transport:)
      client.refresh_token!
      account = client.account
      if account['id'].to_s != user_id.to_s
        return { 'status' => 'other_account', 'message' => "Avito account #{account['id']}" }
      end

      chat = client.chats(user_id, limit: 1).first
      begin
        client.messages(user_id, chat['id'], limit: 1) if chat
      rescue AvitoMessenger::Error::SubscriptionRequired => e
        return { 'status' => 'chat_refused', 'message' => e.message }
      end

      urls = client.subscriptions.filter_map { |subscription| subscription['url'].presence }
      { 'status' => 'ok', 'account' => account['name'], 'messages_checked' => chat.present?,
        'subscriptions' => urls, 'subscribed' => urls.include?(webhook_url(channel)) }
    rescue AvitoMessenger::Error => e
      { 'status' => check_status(e), 'message' => e.message }
    ensure
      transport.finish
    end

    # Avito delivered to the channel's webhook (a probe or a message): the time is kept for the admin page.
    def self.note_webhook(channel, now: Time.zone.now)
      last = channel.preferences[:avito_webhook_at]
      return if last.present? && Time.zone.parse(last.to_s) > now - WEBHOOK_NOTE_INTERVAL

      channel.reload
      channel.preferences[:avito_webhook_at] = now.iso8601
      AuditLog.suspend { channel.save! }
    end

    def self.check_status(error)
      case error
      when AvitoMessenger::Error::Auth                 then 'auth'
      when AvitoMessenger::Error::SubscriptionRequired then 'subscription'
      when AvitoMessenger::Error::RateLimited          then 'rate_limited'
      when AvitoMessenger::Error::Network              then 'network'
      when AvitoMessenger::Error::Api                  then [401, 403].include?(error.status) ? 'auth' : 'error'
      else 'error'
      end
    end

    def self.fetch_account(client)
      client.account
    rescue AvitoMessenger::Error::Auth => e
      raise Invalid, e.message
    rescue AvitoMessenger::Error => e
      raise Invalid, "Avito: #{e.message}"
    end

    def self.duplicate?(user_id, channel)
      AvitoChannel.channels.where.not(id: channel&.id).any? { |other| other.options[:user_id].to_s == user_id.to_s }
    end

    def self.integer_param(params, key, fallback)
      return fallback if !params.key?(key) || params[key].blank?

      Integer(params[key].to_s, 10)
    rescue ArgumentError
      raise Invalid, "#{key} must be a number"
    end

    def self.store_webhook(channel, webhook)
      channel.reload
      channel.options[:webhook] = webhook
      channel.save!
    end

    private_class_method :check_status, :fetch_account, :duplicate?, :integer_param, :store_webhook
  end
end
