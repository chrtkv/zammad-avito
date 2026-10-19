module AvitoChannel
  # The records the channel needs: its article type and admin permission. Created by the migration on a
  # running system, and on demand otherwise (a fresh database runs migrations before its seeds, when the
  # records' creator, user 1, does not exist yet).
  module Setup
    def self.ensure!
      return false if !User.exists?(id: 1)

      Permission.create_if_not_exists(
        name:        PERMISSION,
        label:       'Avito',
        description: 'Manage Avito channel of your system.',
        preferences: { prio: 1295 },
      )

      Ticket::Article::Type.create_if_not_exists(
        name:          ARTICLE_TYPE,
        communication: true,
        updated_by_id: 1,
        created_by_id: 1,
      )

      true
    end
  end
end
