require 'rails_helper'

RSpec.describe 'Avito replies', :aggregate_failures do
  let(:channel) { create_avito_channel }
  let(:account) { AvitoChannelSpecHelpers::AVITO_USER_ID }
  let(:send_url) { "https://api.avito.ru/messenger/v1/accounts/#{account}/chats/chat-1/messages" }
  let(:customer) { create(:customer, firstname: 'Иван', lastname: '', email: 'ivan@example.com') }
  let(:ticket) do
    create(:ticket, customer: customer, group: channel.group,
                    preferences: { channel_id: channel.id, avito: { user_id: account, chat_id: 'chat-1' } })
  end

  def reply(body: 'Да, в наличии.', **attributes)
    create(:ticket_article, ticket: ticket, type: Ticket::Article::Type.lookup(name: 'avito message'), sender_name: 'Agent',
                            content_type: 'text/plain', body: body, internal: false, message_id: nil, **attributes)
  end

  def stub_send(*ids)
    responses = ids.map do |id|
      { status: 200, body: { id: id, created: Time.zone.now.to_i, direction: 'out', type: 'text', content: { text: 'x' } }.to_json,
        headers: { 'Content-Type' => 'application/json' } }
    end
    stub_request(:post, send_url).to_return(*responses)
  end

  before do
    channel
    stub_avito(:post, "/messenger/v1/accounts/#{account}/chats/chat-1/read", body: { ok: true })
  end

  describe 'Ticket::Article::EnqueueCommunicateAvitoJob', performs_jobs: true do
    it 'sends an agent\'s Avito reply' do
      expect { reply }.to have_enqueued_job(CommunicateAvitoJob)
    end

    it 'leaves internal notes, customer messages and imports alone' do
      expect { reply(internal: true) }.not_to have_enqueued_job(CommunicateAvitoJob)
      expect { reply(sender_name: 'Customer') }.not_to have_enqueued_job(CommunicateAvitoJob)
      expect { reply(preferences: { 'avito' => { 'origin' => 'avito' } }) }.not_to have_enqueued_job(CommunicateAvitoJob)
    end
  end

  describe CommunicateAvitoJob, performs_jobs: true do
    it 'sends the reply, records its Avito id and marks the chat read' do
      stub_send('a1')
      article = reply

      described_class.perform_now(article.id)
      article.reload

      expect(a_request(:post, send_url).with(body: { message: { text: 'Да, в наличии.' }, type: 'text' }.to_json)).to have_been_made.once
      expect(article.preferences['delivery_status']).to eq('success')
      expect(article.message_id).to eq("avito.#{account}.chat-1.a1")
      expect(article).to have_attributes(from: 'Demo Shop', to: 'Иван')
      expect(AvitoMessageRef.known?(channel, 'a1')).to be(true)
      expect(a_request(:post, %r{/chats/chat-1/read})).to have_been_made
    end

    it 'splits a long reply into Avito-sized messages' do
      stub_send('a1', 'a2')
      article = reply(body: "#{'Первый абзац. ' * 50}\n\n#{'Второй абзац. ' * 50}")

      described_class.perform_now(article.id)

      expect(a_request(:post, send_url)).to have_been_made.twice
      expect(article.reload.preferences.dig('avito', 'pieces').pluck('message_id')).to eq(%w[a1 a2])
    end

    it 'on a retry sends only what did not go out' do
      stub_send('a2')
      article = reply(preferences: { 'avito' => { 'pieces' => [
                        { 'kind' => 'text', 'text' => 'Часть 1', 'message_id' => 'a1' },
                        { 'kind' => 'text', 'text' => 'Часть 2' },
                      ] } })

      described_class.perform_now(article.id)

      expect(a_request(:post, send_url)).to have_been_made.once
      expect(a_request(:post, send_url).with(body: hash_including('message' => { 'text' => 'Часть 2' }))).to have_been_made
    end

    it 'does not resend a piece Avito took although its answer was lost' do
      attempted = 1.minute.ago.to_i
      stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-1/messages/",
                 body: [{ id: 'a7', author_id: account, created: attempted + 1, direction: 'out', type: 'text', content: { text: 'Часть 1' } }])
      article = reply(preferences: { 'avito' => { 'pieces' => [{ 'kind' => 'text', 'text' => 'Часть 1', 'attempted_at' => attempted }] } })

      described_class.perform_now(article.id)

      expect(a_request(:post, send_url)).not_to have_been_made
      expect(article.reload.preferences.dig('avito', 'pieces', 0, 'message_id')).to eq('a7')
      expect(article.preferences['delivery_status']).to eq('success')
    end

    it 'sends images and refuses other files before sending anything' do
      article = reply(body: 'Чек')
      create(:store, object: 'Ticket::Article', o_id: article.id, data: 'PDF', filename: 'invoice.pdf',
                     preferences: { 'Content-Type' => 'application/pdf' })

      described_class.perform_now(article.id)

      expect(a_request(:post, send_url)).not_to have_been_made
      expect(article.reload.preferences['delivery_status']).to eq('fail')
      expect(article.preferences['delivery_status_message']).to include('invoice.pdf')
      expect(ticket.reload.articles.last.body).to include('Unable to send Avito message')
    end

    it 'uploads an image and sends it after the text' do
      stub_send('a1')
      stub_avito(:post, "/messenger/v1/accounts/#{account}/uploadImages", body: { 'img.1' => { '1280x960' => 'https://img/x.png' } })
      stub_avito(:post, "/messenger/v1/accounts/#{account}/chats/chat-1/messages/image",
                 body: { id: 'a2', author_id: account, created: Time.zone.now.to_i, direction: 'out', type: 'image', content: {} })
      article = reply(body: 'Фото')
      create(:store, object: 'Ticket::Article', o_id: article.id, data: 'PNG', filename: 'photo.png',
                     preferences: { 'Content-Type' => 'image/png' })

      described_class.perform_now(article.id)

      expect(a_request(:post, %r{/messages/image}).with(body: { image_id: 'img.1' }.to_json)).to have_been_made
      expect(article.reload.preferences.dig('avito', 'pieces').pluck('message_id')).to eq(%w[a1 a2])
    end

    it 'reports a missing Messenger API subscription and retries' do
      stub_request(:post, send_url).to_return(status: 402, body: { error: { code: 402, message: 'Перейдите на подписку с API мессенджера' } }.to_json)
      article = reply

      expect { described_class.perform_now(article.id) }.to have_enqueued_job(described_class)

      expect(article.reload.preferences['delivery_status']).to eq('fail')
      expect(article.preferences['delivery_status_message']).to include('подписку с API мессенджера')
    end
  end
end
