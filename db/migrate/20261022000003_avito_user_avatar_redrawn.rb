# The "Avito" user's avatar redrawn after Avito's app icon (2026-10-22): the first one had the dots' colours
# and sizes wrong.
class AvitoUserAvatarRedrawn < ActiveRecord::Migration[8.0]
  def up
    return if !Setting.exists?(name: 'system_init_done')

    user = User.find_by(login: AvitoChannel::ServiceUser::AVITO_LOGIN)
    AvitoChannel::ServiceUser.avito_avatar!(user) if user
  end
end
