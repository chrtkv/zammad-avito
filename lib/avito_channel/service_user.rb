module AvitoChannel
  # The Zammad user that messages written in Avito itself (the website, the app, autoresponders) are filed
  # under: one per account, named after it and wearing its Avito avatar, so such replies are told apart from
  # agents' at a glance. Active, so Zammad shows their avatars (an inactive user's is grey and nearly transparent),
  # but without a password or an e-mail: nobody can sign in as them.
  module ServiceUser
    AVITO_LOGIN = 'avito.system'.freeze
    # Avito's mark as in its app icon (avito.st/s/app/logo/180.png, measured 2026-10-22): the "Avito" user's avatar.
    AVITO_AVATAR = File.expand_path('avito_avatar.png', __dir__)

    def self.for(channel, profile = nil)
      user_id = channel.options[:user_id]
      login   = "avito.account.#{user_id}"

      User.find_by(login: login) || create(channel, login, profile)
    end

    def self.create(channel, login, profile)
      user = User.create!(
        login:         login,
        firstname:     channel.options[:name].presence || "Avito #{channel.options[:user_id]}",
        lastname:      '(Avito)',
        note:          "Messages written in Avito itself for account #{channel.options[:user_id]}",
        active:        true,
        role_ids:      Role.signup_role_ids,
        updated_by_id: 1,
        created_by_id: 1,
      )
      AvitoChannel.add_avatar(user, profile)
      user
    end

    # The user Avito's own notices (a chat opened without a message, its bots) are filed under: one for the
    # system, named "Avito" in the system's language, so such a note reads as written by the platform, neither
    # by the shop nor by Zammad. Active and without a password, as above; it gets Avito's mark as its avatar, also
    # when it was made before it had one.
    def self.avito
      user = User.find_by(login: AVITO_LOGIN) || User.create!(
        login:         AVITO_LOGIN,
        firstname:     AvitoChannel.translate(__('Avito')),
        lastname:      '',
        active:        true,
        role_ids:      Role.signup_role_ids,
        updated_by_id: 1,
        created_by_id: 1,
      )
      avito_avatar!(user) if user.image.blank? || user.image == 'none'
      user
    end

    # Sets AVITO_AVATAR as the user's avatar, replacing one from before. A picture that cannot be stored leaves
    # what was there, never fails the import.
    def self.avito_avatar!(user)
      content = File.binread(AVITO_AVATAR)
      avatar  = Avatar.add(object: 'User', o_id: user.id, full: { content:, mime_type: 'image/png' },
                           resize: { content:, mime_type: 'image/png' }, source: 'avito', deletable: true,
                           updated_by_id: 1, created_by_id: 1)
      user.update!(image: avatar.store_hash) if avatar
    rescue => e
      Rails.logger.warn "Avatar of the Avito user not set: #{e.message}"
    end

    private_class_method :create
  end
end
