module AvitoChannel
  # The records the channel needs: its article type and admin permission. Created by the migration on a
  # running system, and on demand otherwise (a fresh database runs migrations before its seeds, when the
  # records' creator, user 1, does not exist yet).
  module Setup
    # Russian for the channel's interface and for the texts it writes into tickets. Stored as custom
    # translations, so an admin can change them under Admin → Translations, and one already there is left
    # alone. Setup runs from the migration: a text added later needs a migration that calls it again.
    TRANSLATIONS = {
      'ru' => {
        # Interface
        'Accounts'                                                               => 'Аккаунты',
        'Add Account'                                                            => 'Добавить аккаунт',
        'Add Avito Account'                                                      => 'Подключить аккаунт Авито',
        'Avito Account'                                                          => 'Аккаунт Авито',
        'Avito API keys'                                                         => 'Ключи API Авито',
        'Are you sure? Messages already in tickets stay, new ones will no longer arrive.' =>
                                                                                    'Удалить? Сообщения, уже попавшие в тикеты, останутся, новые приходить перестанут.',
        "Each Avito account needs the Messenger API subscription and its own client ID and secret from the account's API settings." =>
                                                                                    'Для каждого аккаунта Авито нужна подписка на Messenger API и свои Client ID и секрет из настроек API аккаунта.',
        "From the Avito account's API settings (\"Интеграции и API\"). The account needs the Messenger API subscription." =>
                                                                                    'Из настроек API аккаунта Авито («Интеграции и API»). Аккаунту нужна подписка на Messenger API.',
        'Client ID'                                                              => 'Client ID',
        'Client secret'                                                          => 'Секрет (client secret)',
        'Chats'                                                                  => 'Чаты',
        'Check for missed messages every (seconds)'                              => 'Проверять пропущенные сообщения каждые (секунд)',
        'Messages arrive through the webhook at once; this check picks up what it missed and messages written in Avito itself.' =>
                                                                                    'Сообщения приходят через вебхук сразу; эта проверка подбирает пропущенные и написанные в самом Авито.',
        'Import history (days)'                                                  => 'Загрузить историю (дней)',
        'On connecting, messages of this many past days are imported. 0 starts with new messages only.' =>
                                                                                    'При подключении загружаются сообщения за столько последних дней. 0 — только новые.',
        'Mark the chat read in Avito when an agent replies'                      => 'Отмечать чат в Авито прочитанным, когда агент отвечает',
        'Public URL for the webhook'                                             => 'Публичный адрес для вебхука',
        "Leave empty to use this system's address. Avito must be able to reach it." =>
                                                                                    'Пусто — адрес этой системы. Авито должен до него доставать.',
        'Polling'                                                                => 'Опрос',
        'Not polled yet'                                                         => 'Ещё не опрашивался',
        'Subscribed'                                                             => 'Подписан',
        'Not subscribed'                                                         => 'Не подписан',
        'Subscribe webhook again'                                                => 'Подписать вебхук заново',
        'The Avito account could not be saved.'                                  => 'Не удалось сохранить аккаунт Авито.',
        'Client ID and client secret are required.'                              => 'Нужны Client ID и секрет.',
        'Please choose a group.'                                                 => 'Выберите группу.',
        'Avito did not return the account id.'                                   => 'Авито не вернул id аккаунта.',
        'This Avito account is already connected.'                               => 'Этот аккаунт Авито уже подключён.',
        'Listing'                                                                => 'Объявление',
        'Shop'                                                                   => 'Магазин',
        'Without a listing (chat with the profile)'                              => 'Без объявления (чат по профилю)',
        'Open the chat in Avito'                                                 => 'Открыть чат в Авито',
        'Avito does not give out this chat through the API. Read and reply in Avito.' =>
                                                                                    'Авито не отдаёт этот чат через API. Читайте и отвечайте в Авито.',
        # Texts written into tickets
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
