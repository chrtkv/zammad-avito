require 'rails_helper'

RSpec.describe 'Avito channel', :aggregate_failures, type: :request do
  let(:channel) { create_avito_channel }

  describe 'POST /api/v1/channels_avito_webhook/:callback_token', performs_jobs: true do
    def deliver(body, token: channel.options[:callback_token])
      post "/api/v1/channels_avito_webhook/#{token}", params: body.to_json, headers: { 'Content-Type' => 'application/json' }
    end

    it 'queues a customer message for import at once' do
      value = avito_message(id: 'm1')

      expect { deliver(avito_webhook_body(value)) }
        .to have_enqueued_job(AvitoImportJob).with(channel.id, value)
      expect(response).to have_http_status(:ok)
    end

    it 'queues an own message a minute late, so the echo of a Zammad reply is recognised' do
      value = avito_message(id: 'm2', author_id: AvitoChannelSpecHelpers::AVITO_USER_ID)

      freeze_time do
        expect { deliver(avito_webhook_body(value)) }
          .to have_enqueued_job(AvitoImportJob).with(channel.id, value).at(1.minute.from_now)
      end
    end

    it 'answers Avito\'s {} probe with 200 and queues nothing' do
      expect { deliver({}) }.not_to have_enqueued_job(AvitoImportJob)
      expect(response).to have_http_status(:ok)
    end

    it 'refuses an unknown callback token' do
      channel
      expect { deliver(avito_webhook_body(avito_message(id: 'm1')), token: 'wrong') }.not_to have_enqueued_job(AvitoImportJob)
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses an event for another account' do
      value = avito_message(id: 'm1', user_id: 1)

      expect { deliver(avito_webhook_body(value)) }.not_to have_enqueued_job(AvitoImportJob)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'routes each account\'s events by its own token' do
      other = create_avito_channel(user_id: 111, name: 'Second shop')
      value = avito_message(id: 'm1', user_id: 111)

      expect { deliver(avito_webhook_body(value), token: other.options[:callback_token]) }
        .to have_enqueued_job(AvitoImportJob).with(other.id, value)
      expect { deliver(avito_webhook_body(value), token: channel.options[:callback_token]) }.not_to have_enqueued_job(AvitoImportJob)
    end

    it 'takes deliveries for a disabled account without importing them' do
      channel.update!(active: false)

      expect { deliver(avito_webhook_body(avito_message(id: 'm1'))) }.not_to have_enqueued_job(AvitoImportJob)
      expect(response).to have_http_status(:ok)
    end

    it 'refuses a body that is not a delivery' do
      deliver({ 'payload' => 'nonsense' })
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'account administration', authenticated_as: :admin do
    let(:admin) { create(:admin) }

    before do
      AvitoChannel::Setup.ensure!
      Setting.set('http_type', 'https')
      Setting.set('fqdn', 'hd.example.com')
    end

    describe 'POST /api/v1/channels_avito' do
      before do
        stub_avito(:post, '/token', body: { access_token: 'new-token', expires_in: 86_400 })
        stub_avito(:get, '/core/v1/accounts/self', body: { id: 777, name: 'New shop' })
        stub_avito(:post, '/messenger/v3/webhook', body: { ok: true })
      end

      let(:params) { { client_id: 'cid', client_secret: 'csecret', group_id: Group.first.id } }

      it 'connects the account, subscribes its webhook and masks the secret' do
        post '/api/v1/channels_avito', params: params, as: :json

        expect(response).to have_http_status(:ok)
        channel = Channel.find(json_response['id'])
        expect(channel.options).to include('user_id' => 777, 'name' => 'New shop')
        expect(channel.options.dig('auth', 'client_secret')).to eq('csecret')
        expect(json_response.dig('options', 'auth', 'client_secret')).to eq(SensitiveParamsHelper::SENSITIVE_MASK)
        expect(json_response.dig('options', 'auth', 'access_token')).to eq(SensitiveParamsHelper::SENSITIVE_MASK)

        url = "https://hd.example.com/api/v1/channels_avito_webhook/#{channel.options[:callback_token]}"
        expect(a_request(:post, 'https://api.avito.ru/messenger/v3/webhook').with(body: { url: url }.to_json)).to have_been_made
        expect(channel.options.dig('webhook', 'url')).to eq(url)
        expect(channel.options.dig('webhook', 'error')).to be_nil
      end

      it 'keeps the account but reports a webhook Avito refused' do
        stub_avito(:post, '/messenger/v3/webhook', status: 402,
                                                   body: { error: { code: 402, message: 'Перейдите на подписку с API мессенджера' } })

        post '/api/v1/channels_avito', params: params, as: :json

        expect(response).to have_http_status(:ok)
        expect(json_response.dig('options', 'webhook', 'error')).to include('подписку с API мессенджера')
      end

      it 'refuses credentials Avito rejects' do
        stub_avito(:post, '/token', body: { error: 'invalid_client', error_description: 'bad secret' })

        expect { post '/api/v1/channels_avito', params: params, as: :json }.not_to change(Channel, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response['error']).to include('bad secret')
      end

      it 'refuses to connect the same account twice' do
        create_avito_channel(user_id: 777)

        expect { post '/api/v1/channels_avito', params: params, as: :json }.not_to change(Channel, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    describe 'PUT /api/v1/channels_avito/:id' do
      before do
        stub_avito(:post, '/token', body: { access_token: 'renewed', expires_in: 86_400 })
        stub_avito(:get, '/core/v1/accounts/self', body: { id: AvitoChannelSpecHelpers::AVITO_USER_ID, name: 'Renamed' })
      end

      it 'moves the webhook when its address changes: unsubscribes the old one, subscribes the new one' do
        old_url = AvitoChannel::Account.webhook_url(channel)
        channel.options[:webhook] = { 'url' => old_url, 'subscribed_at' => 1.day.ago.iso8601, 'error' => nil }
        channel.save!
        stub_avito(:post, '/messenger/v1/webhook/unsubscribe', body: { ok: true })
        stub_avito(:post, '/messenger/v3/webhook', body: { ok: true })

        put "/api/v1/channels_avito/#{channel.id}", params: { webhook_base_url: 'https://new.example' }, as: :json

        new_url = "https://new.example/api/v1/channels_avito_webhook/#{channel.options[:callback_token]}"
        expect(response).to have_http_status(:ok)
        expect(a_request(:post, 'https://api.avito.ru/messenger/v1/webhook/unsubscribe').with(body: { url: old_url }.to_json)).to have_been_made
        expect(a_request(:post, 'https://api.avito.ru/messenger/v3/webhook').with(body: { url: new_url }.to_json)).to have_been_made
        expect(channel.reload.options[:webhook]).to include('url' => new_url, 'error' => nil)
      end

      it 'keeps the stored secret when the form sends back the mask' do
        put "/api/v1/channels_avito/#{channel.id}",
            params: { client_secret: SensitiveParamsHelper::SENSITIVE_MASK, backfill_days: 3 }, as: :json

        expect(response).to have_http_status(:ok)
        channel.reload
        expect(channel.options.dig('auth', 'client_secret')).to eq("secret-#{AvitoChannelSpecHelpers::AVITO_USER_ID}")
        expect(channel.options).to include('name' => 'Renamed', 'callback_token' => "callback-#{AvitoChannelSpecHelpers::AVITO_USER_ID}")
        expect(channel.options.dig('sync', 'backfill_days')).to eq(3)
      end
    end

    describe 'DELETE /api/v1/channels_avito/:id' do
      it 'removes the webhook and forgets the account\'s messages' do
        stub_avito(:post, '/messenger/v1/webhook/unsubscribe', body: { ok: true })
        AvitoMessageRef.claim!(channel, 'chat-1', 'm1')

        delete "/api/v1/channels_avito/#{channel.id}", as: :json

        expect(response).to have_http_status(:ok)
        expect(Channel.exists?(channel.id)).to be(false)
        expect(AvitoMessageRef.where(channel_id: channel.id)).to be_empty
        expect(a_request(:post, 'https://api.avito.ru/messenger/v1/webhook/unsubscribe')).to have_been_made
      end
    end

    describe 'GET /api/v1/channels_avito' do
      it 'lists accounts with their webhook URLs and masked secrets' do
        channel
        get '/api/v1/channels_avito', as: :json

        expect(json_response['channel_ids']).to eq([channel.id])
        expect(json_response.dig('webhook_urls', channel.id.to_s))
          .to eq("https://hd.example.com/api/v1/channels_avito_webhook/#{channel.options[:callback_token]}")
        expect(json_response.dig('assets', 'Channel', channel.id.to_s, 'options', 'auth', 'client_secret'))
          .to eq(SensitiveParamsHelper::SENSITIVE_MASK)
      end
    end

    context 'when signed in as an agent', authenticated_as: :agent do
      let(:agent) { create(:agent) }

      it 'refuses access' do
        get '/api/v1/channels_avito', as: :json
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
