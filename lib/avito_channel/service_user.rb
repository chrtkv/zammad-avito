module AvitoChannel
  # The Zammad user that messages written in Avito itself (the website, the app, autoresponders) are filed
  # under: one per account, named after it and wearing its Avito avatar, so such replies are told apart from
  # agents' at a glance. Inactive, without a password: nobody signs in as it.
  module ServiceUser
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
        active:        false,
        role_ids:      Role.signup_role_ids,
        updated_by_id: 1,
        created_by_id: 1,
      )
      AvitoChannel.add_avatar(user, profile)
      user
    end
    private_class_method :create
  end
end
