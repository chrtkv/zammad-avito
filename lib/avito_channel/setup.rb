module AvitoChannel
  # The records the channel needs: its article type and admin permission. Created by the migration on a
  # running system, and on demand otherwise (a fresh database runs migrations before its seeds, when the
  # records' creator, user 1, does not exist yet).
  module Setup
    # Russian for the texts the channel writes into tickets. Stored as custom translations, so an admin can
    # change them under Admin → Translations, and a translation already there is left alone.
    TRANSLATIONS = {
      'ru' => {
        'Image'                                                                  => 'Изображение',
        'Voice message'                                                          => 'Голосовое сообщение',
        'Missed call'                                                            => 'Пропущенный звонок',
        'The message was deleted'                                                => 'Сообщение удалено',
        'Avito "%s" message: its content is not available through the API'      => 'Сообщение Авито типа «%s»: его содержимое недоступно через API',
        "Avito does not give out this chat's messages through the API: the Messenger API subscription does not cover it, most likely because of the listing's category. Only the chat's latest message reaches this ticket; earlier ones may be missing. Read the chat and reply in Avito." =>
                                                                                    'Авито не отдаёт сообщения этого чата через API: подписка на Messenger API его не покрывает, скорее всего из-за категории объявления. В тикет попадает только последнее сообщение чата, более ранние могли не попасть. Читайте чат и отвечайте в Авито.',
      },
    }.freeze

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

      TRANSLATIONS.each do |locale, pairs|
        pairs.each do |source, target|
          next if Translation.exists?(locale: locale, source: source)

          Translation.create!(locale: locale, source: source, target: target, target_initial: target,
                              is_synchronized_from_codebase: false, created_by_id: 1, updated_by_id: 1)
        end
      end

      true
    end
  end
end
