# The users Avito's messages are filed under, made before 2026-10-22, are made active: Zammad greys out an
# inactive user's avatar almost to nothing. They have no password or e-mail, so nobody can sign in as them. The
# "Avito" user of Avito's notices also gets its avatar (AvitoChannel::ServiceUser).
class AvitoServiceUsersVisible < ActiveRecord::Migration[8.0]
  def up
    return if !Setting.exists?(name: 'system_init_done')

    User.where('login LIKE ?', 'avito.account.%').or(User.where(login: AvitoChannel::ServiceUser::AVITO_LOGIN))
      .where(active: false).find_each { |user| user.update!(active: true) }

    AvitoChannel::ServiceUser.avito if User.exists?(login: AvitoChannel::ServiceUser::AVITO_LOGIN)
  end
end
