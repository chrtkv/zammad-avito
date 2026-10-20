# Helpers for the Avito channel specs: an account channel with a live token, and Avito API stubs.
module AvitoChannelSpecHelpers
  AVITO_API      = 'https://api.avito.ru'.freeze
  AVITO_USER_ID  = 12_345_678
  AVITO_BUYER_ID = 87_654_321
  PNG            = Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

  def create_avito_channel(user_id: AVITO_USER_ID, name: 'Demo Shop', group: Group.find_by(name: 'Users'), **options)
    AvitoChannel::Setup.ensure!
    Channel.create!(
      area:          AvitoChannel::AREA,
      group:         group,
      active:        true,
      options:       {
        adapter:        AvitoChannel::ADAPTER,
        auth:           {
          client_id:               "client-#{user_id}",
          client_secret:           "secret-#{user_id}",
          access_token:            "token-#{user_id}",
          access_token_expires_at: 1.day.from_now.to_i,
        },
        user_id:        user_id,
        name:           name,
        callback_token: "callback-#{user_id}",
        sync:           { backfill_days: 0, poll_interval: 300 },
      }.merge(options),
      updated_by_id: 1,
      created_by_id: 1,
    )
  end

  def avito_message(id:, chat_id: 'chat-1', author_id: AVITO_BUYER_ID, type: 'text', text: 'Здравствуйте!',
                    created: Time.zone.now.to_i, user_id: AVITO_USER_ID, content: nil, **extra)
    {
      'id'        => id,
      'chat_id'   => chat_id,
      'user_id'   => user_id,
      'author_id' => author_id,
      'type'      => type,
      'chat_type' => 'u2i',
      'created'   => created,
      'content'   => content || { 'text' => text },
    }.merge(extra.stringify_keys)
  end

  def avito_webhook_body(value)
    { 'id' => SecureRandom.uuid, 'version' => 'v3.0.0', 'timestamp' => Time.zone.now.to_i,
      'payload' => { 'type' => 'message', 'value' => value } }
  end

  def avito_chat(id: 'chat-1', user_id: AVITO_USER_ID, buyer_id: AVITO_BUYER_ID, buyer_name: 'Иван', updated: Time.zone.now.to_i,
                 item: { 'id' => 1_234_567_890, 'title' => 'Горный велосипед, 29 дюймов', 'url' => 'https://www.avito.ru/item/1',
                         'price_string' => '5 000 ₽' })
    {
      'id'      => id,
      'created' => updated - 3600,
      'updated' => updated,
      'context' => item ? { 'type' => 'item', 'value' => item } : nil,
      'users'   => [
        { 'id' => user_id, 'name' => 'Demo Shop',
          'public_user_profile' => { 'user_id' => user_id, 'avatar' => { 'default' => "https://www.avito.ru/test-avatar/#{user_id}.png",
                                                                         'images'  => { '256x256' => "https://www.avito.ru/test-avatar/#{user_id}-256.png" } } } },
        { 'id' => buyer_id, 'name' => buyer_name,
          'public_user_profile' => { 'user_id' => buyer_id, 'url' => "https://www.avito.ru/user/#{buyer_id}",
                                     'avatar' => { 'images' => { '256x256' => "https://www.avito.ru/test-avatar/#{buyer_id}-256.png" } } } },
      ],
    }.compact
  end

  def stub_avito_chat(chat, user_id: AVITO_USER_ID)
    stub_request(:get, "#{AVITO_API}/messenger/v2/accounts/#{user_id}/chats/#{chat['id']}")
      .to_return(status: 200, body: chat.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_avito(method, path, body: {}, status: 200, headers: {})
    stub_request(method, %r{\A#{Regexp.escape(AVITO_API)}#{path}(\?.*)?\z})
      .to_return(status: status, body: body.is_a?(String) ? body : body.to_json,
                 headers: { 'Content-Type' => 'application/json' }.merge(headers))
  end
end

RSpec.configure do |config|
  config.include AvitoChannelSpecHelpers

  # Avatars of Avito users: a tiny PNG for any of them, unless a spec says otherwise.
  config.before do
    stub_request(:get, %r{\Ahttps://www\.avito\.ru/test-avatar/})
      .to_return(status: 200, body: AvitoChannelSpecHelpers::PNG, headers: { 'Content-Type' => 'image/png' })
  end
end
