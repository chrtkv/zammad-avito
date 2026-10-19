RSpec.describe AvitoMessenger::Client do
  let(:now)       { Time.utc(2026, 10, 20, 12, 0, 0) }
  let(:user_id)   { 12_345_678 }
  let(:chat_id)   { 'u2i-AbCdEfGhIjKlMnOpQrStUv' }
  let(:transport) { FakeTransport.new(*responses) }
  let(:stored)    { [] }
  let(:token)     { AvitoMessenger::Token.new(access_token: 'cached', expires_at: now + 3600) }
  let(:client) do
    described_class.new(client_id: 'id', client_secret: 'secret', token:, transport:, clock: -> { now },
                        on_token: ->(t) { stored << t })
  end

  let(:token_ok) { [200, { 'access_token' => 'fresh', 'expires_in' => 86_400, 'token_type' => 'Bearer' }] }

  describe '#refresh_token!' do
    let(:token) { nil }

    context 'when Avito accepts the credentials' do
      let(:responses) { [token_ok] }

      it 'posts the client credentials as a form and keeps the token for a day' do
        client.refresh_token!

        request = transport.requests.first
        expect(request.path).to eq('/token')
        expect(URI.decode_www_form(request.body).to_h)
          .to eq('grant_type' => 'client_credentials', 'client_id' => 'id', 'client_secret' => 'secret')
        expect(client.token.access_token).to eq('fresh')
        expect(client.token.expires_at).to eq(now + 86_400)
        expect(stored.map(&:access_token)).to eq(['fresh'])
      end
    end

    # Seen on the live API on 2026-10-19: a bad request to /token answers HTTP 200 with an error body.
    context 'when Avito answers 200 with an error body' do
      let(:responses) do
        [[200, { 'error' => 'invalid_request', 'error_description' => 'The request is missing a required parameter' }]]
      end

      it 'raises an auth error carrying Avito\'s description' do
        expect { client.refresh_token! }
          .to raise_error(AvitoMessenger::Error::Auth, /invalid_request: The request is missing/)
        expect(stored).to be_empty
      end
    end
  end

  describe 'token reuse' do
    let(:responses) { [[200, { 'id' => user_id, 'name' => 'Demo Shop' }]] }

    it 'uses a stored token that is not about to expire' do
      expect(client.account['id']).to eq(user_id)
      expect(transport.requests.map(&:path)).to eq(['/core/v1/accounts/self'])
      expect(transport.requests.first.headers['Authorization']).to eq('Bearer cached')
    end

    context 'when the stored token expires within the refresh margin' do
      let(:token)     { AvitoMessenger::Token.new(access_token: 'cached', expires_at: now + 120) }
      let(:responses) { [token_ok, [200, { 'id' => user_id }]] }

      it 'refreshes first' do
        client.account
        expect(transport.requests.map(&:path)).to eq(['/token', '/core/v1/accounts/self'])
        expect(transport.requests.last.headers['Authorization']).to eq('Bearer fresh')
      end
    end
  end

  describe 'a revoked token' do
    context 'when the retry with a fresh token succeeds' do
      let(:responses) { [[401, { 'message' => 'Unauthorized' }], token_ok, [200, { 'id' => user_id }]] }

      it 'refreshes once and repeats the request' do
        expect(client.account['id']).to eq(user_id)
        expect(transport.requests.map(&:path)).to eq(['/core/v1/accounts/self', '/token', '/core/v1/accounts/self'])
      end
    end

    # Seen on the live API on 2026-10-20: an invalid token gets 403, not 401.
    context 'when Avito refuses the token with 403' do
      let(:responses) do
        [[403, { 'result' => { 'status' => false, 'message' => 'invalid access token' } }], token_ok, [200, { 'id' => user_id }]]
      end

      it 'refreshes once and repeats the request' do
        expect(client.account['id']).to eq(user_id)
        expect(transport.requests.map(&:path)).to eq(['/core/v1/accounts/self', '/token', '/core/v1/accounts/self'])
      end
    end

    context 'when a 403 is about something else' do
      let(:responses) { [[403, { 'result' => { 'status' => false, 'message' => 'forbidden for this item' } }]] }

      it 'reports it without a refresh, with Avito\'s message' do
        expect { client.account }.to raise_error(AvitoMessenger::Error::Api, /403: forbidden for this item/)
        expect(transport.requests.size).to eq(1)
      end
    end

    context 'when the fresh token is refused too' do
      let(:responses) { [[401, {}], token_ok, [401, { 'message' => 'Unauthorized' }]] }

      it 'reports the 401 instead of looping' do
        expect { client.account }.to raise_error(AvitoMessenger::Error::Api) { |e| expect(e.status).to eq(401) }
        expect(transport.requests.size).to eq(3)
      end
    end
  end

  describe 'error answers' do
    # The 402 text is what the live API returned for our account on 2026-10-19.
    context 'when the account has no Messenger API subscription' do
      let(:responses) do
        [[402, { 'error' => { 'code' => 402,
                              'message' => 'Перейдите на подписку с API мессенджера, чтобы получить доступ к чатам' } }]]
      end

      it 'raises SubscriptionRequired with Avito\'s message' do
        expect { client.messages(user_id, chat_id) }
          .to raise_error(AvitoMessenger::Error::SubscriptionRequired, /подписку с API мессенджера/)
      end
    end

    context 'when rate limited' do
      let(:responses) { [[429, { 'message' => 'Too many requests' }, { 'retry-after' => '17' }]] }

      it 'raises RateLimited with the delay Avito asked for' do
        expect { client.account }.to raise_error(AvitoMessenger::Error::RateLimited) { |e| expect(e.retry_after).to eq(17) }
      end
    end

    context 'when rate limited without a delay' do
      let(:responses) { [[429, '']] }

      it 'falls back to a minute' do
        expect { client.account }.to raise_error(AvitoMessenger::Error::RateLimited) { |e| expect(e.retry_after).to eq(60) }
      end
    end

    context 'when a success is not JSON' do
      let(:responses) { [[200, '<html>maintenance</html>']] }

      it 'raises BadPayload' do
        expect { client.account }.to raise_error(AvitoMessenger::Error::BadPayload)
      end
    end
  end

  describe '#messages' do
    let(:responses) { [[200, fixture('messages_v3').to_json]] }

    it 'reads the v3 list with its trailing slash and pagination' do
      client.messages(user_id, chat_id, offset: 100)

      request = transport.requests.first
      expect(request.path).to eq("/messenger/v3/accounts/#{user_id}/chats/#{chat_id}/messages/")
      expect(request.query_pairs).to contain_exactly(%w[limit 100], %w[offset 100])
    end

    it 'returns messages tied to the account and chat' do
      messages = client.messages(user_id, chat_id)

      expect(messages.map(&:id)).to eq(%w[m3 m2 m1])
      expect(messages.map(&:origin)).to eq(%i[own customer customer])
      expect(messages).to all(have_attributes(chat_id:, account_user_id: user_id))
    end
  end

  describe '#chats' do
    let(:responses) { [[200, { 'chats' => [{ 'id' => chat_id, 'updated' => 1_760_900_300 }] }]] }

    it 'sends chat types as repeated keys' do
      expect(client.chats(user_id).map { |chat| chat['id'] }).to eq([chat_id])
      expect(transport.requests.first.query_pairs)
        .to contain_exactly(%w[limit 100], %w[offset 0], %w[chat_types u2i], %w[chat_types u2u])
    end
  end

  describe '#send_text' do
    let(:responses) do
      [[200, { 'id' => 'sent1', 'created' => 1_760_900_400, 'direction' => 'out', 'type' => 'text',
               'content' => { 'text' => 'Да' } }]]
    end

    it 'posts a text message and returns it as our own' do
      message = client.send_text(user_id, chat_id, 'Да')

      expect(transport.requests.first.json).to eq('message' => { 'text' => 'Да' }, 'type' => 'text')
      expect(message).to have_attributes(id: 'sent1', chat_id:, own?: true)
    end

    it 'refuses text over the limit instead of letting Avito cut it' do
      expect { client.send_text(user_id, chat_id, 'я' * 1001) }.to raise_error(ArgumentError, /1001/)
      expect(transport.requests).to be_empty
    end
  end

  describe '#upload_image' do
    let(:responses) { [[200, { '12345.abcdef' => { '1280x960' => 'https://img.example/1.png' } }]] }

    it 'uploads as multipart under uploadfile[] and returns the image id' do
      image_id = client.upload_image(user_id, filename: 'photo.png', content: "\x89PNG\x00".b, content_type: 'image/png')

      request = transport.requests.first
      expect(image_id).to eq('12345.abcdef')
      expect(request.headers['Content-Type']).to start_with('multipart/form-data; boundary=')
      expect(request.body).to include('name="uploadfile[]"; filename="photo.png"'.b)
      expect(request.body).to include("\x89PNG\x00".b)
    end
  end
end
