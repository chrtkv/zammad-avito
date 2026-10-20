# Zammad side of the Avito channel: accounts as channels, Avito messages as articles, replies back to Avito.
# The Avito API itself is AvitoMessenger (lib/avito_messenger). See docs/DESIGN.md.
module AvitoChannel
  AREA          = 'Avito::Account'.freeze
  ADAPTER       = 'avito'.freeze
  ARTICLE_TYPE  = 'avito message'.freeze
  PERMISSION    = 'admin.channel_avito'.freeze
  AUTH_PROVIDER = 'avito'.freeze

  # Own messages are imported this long after Avito reports them, so the send that produced them has had
  # time to record its message id (otherwise the echo of a Zammad reply would come back as a second one).
  OWN_MESSAGE_DELAY = 60

  # Default seconds between reconciliation polls of one account.
  POLL_INTERVAL = 300

  def self.channels
    Channel.where(area: AREA)
  end

  # Where the Avito API is reached. AVITO_API_BASE_URL overrides it, e.g. for a tunnel through another host
  # (https://api.avito.ru:18443 with api.avito.ru resolving to the tunnel), keeping TLS checked against
  # Avito's own name.
  def self.api_base_url
    ENV['AVITO_API_BASE_URL'].presence || AvitoMessenger::Client::BASE_URL
  end

  def self.article_type
    Ticket::Article::Type.lookup(name: ARTICLE_TYPE) || Setup.ensure!.then { Ticket::Article::Type.lookup(name: ARTICLE_TYPE) }
  end

  # Article message_id for an Avito message; unique per account.
  def self.message_id(user_id, chat_id, avito_message_id)
    "avito.#{user_id}.#{chat_id}.#{avito_message_id}"
  end

  # A client for the channel's account. A refreshed token is written back to the channel.
  def self.client(channel, transport: AvitoMessenger::Transport.new)
    auth = channel.options[:auth] || {}

    AvitoMessenger::Client.new(
      client_id:     auth[:client_id],
      client_secret: auth[:client_secret],
      token:         AvitoMessenger::Token.from_h({ access_token: auth[:access_token], expires_at: auth[:access_token_expires_at] }),
      transport:     transport,
      on_token:      ->(token) { store_token(channel, token) },
      base_url:      api_base_url,
    )
  end

  def self.store_token(channel, token)
    return if channel.new_record?

    channel.reload
    channel.options[:auth][:access_token]            = token.access_token
    channel.options[:auth][:access_token_expires_at] = token.expires_at.to_i

    # A daily token refresh is not an admin action: keep it out of the audit log, as Zammad does for XOAUTH2.
    AuditLog.suspend { channel.save! }
  end

  # Gives a user the avatar of their Avito profile (a chat participant's public_user_profile). Zammad fetches
  # the image itself; a picture that cannot be fetched leaves the initials, never fails the import.
  def self.add_avatar(user, profile)
    avatar = profile.is_a?(Hash) ? profile.dig('public_user_profile', 'avatar') : nil
    return if !avatar.is_a?(Hash)

    url = (avatar['images'].is_a?(Hash) && avatar['images']['256x256']).presence || avatar['default'].presence
    return if url.blank?

    avatar = Avatar.add(object: 'User', o_id: user.id, url: url, source: 'avito', deletable: true,
                        updated_by_id: 1, created_by_id: 1)
    # Avatar.add stores the picture; the user shows it once it is linked, as AvatarCreateJob does.
    user.update!(image: avatar.store_hash) if avatar
  rescue => e
    Rails.logger.warn "Avito avatar of user #{user.id} not set: #{e.message}"
  end

  # The internal note on a ticket whose chat Avito does not give out through the API.
  def self.uncovered_note(item_url)
    locale = Setting.get('locale_default') || 'en-us'
    text   = Translation.translate(locale, __("Avito does not give out this chat's messages through the API: the Messenger API subscription does not cover it, most likely because of the listing's category. Only the chat's latest message reaches this ticket; earlier ones may be missing. Read the chat and reply in Avito."))
    [text, item_url.presence, 'https://www.avito.ru/profile/messenger'].compact.join("\n")
  end

  # Texts for Avito messages that carry none, in the system's default language.
  def self.labels
    locale = Setting.get('locale_default') || 'en-us'
    {
      image:       Translation.translate(locale, __('Image')),
      voice:       Translation.translate(locale, __('Voice message')),
      missed_call: Translation.translate(locale, __('Missed call')),
      deleted:     Translation.translate(locale, __('The message was deleted')),
      unsupported: Translation.translate(locale, __('Avito "%s" message: its content is not available through the API')),
    }
  end
end
