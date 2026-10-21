require 'rails_helper'

# Scenarios from the code review of 2026-10-21; each one failed before its fix.

RSpec.describe 'Avito review regression scenarios', :aggregate_failures do
  let(:channel) { create_avito_channel }
  let(:account) { AvitoChannelSpecHelpers::AVITO_USER_ID }
  let(:importer) { AvitoChannel::Importer.new(channel) }
  let(:now) { Time.zone.now.change(usec: 0) }

  before { stub_avito_chat(avito_chat) }

  def ingest(id, **args)
    importer.import(AvitoMessenger::Message.from_hash(avito_message(id: id, **args)))
  end

  def agent_reply(ticket, **args)
    create(:ticket_article, ticket: ticket, type: AvitoChannel.article_type, sender_name: 'Agent',
                            content_type: 'text/plain', body: 'Reply', internal: false, message_id: nil, **args)
  end

  it 'recovers old missed messages after a chat was deferred for being too recent' do
    channel.update!(preferences: { avito_cursor: (now - 10.minutes).to_i })
    last = avito_message(id: 'recent', created: (now - 10.seconds).to_i)
    chat = avito_chat.merge('last_message' => last)
    stub_avito(:get, "/messenger/v2/accounts/#{account}/chats", body: { chats: [chat] })
    stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-1/messages/", body: [
      last, avito_message(id: 'missed', created: (now - 8.minutes).to_i),
    ])
    AvitoChannel::Sync.new(channel, now: now).run
    AvitoChannel::Sync.new(channel.reload, now: now + 5.minutes).run
    expect(AvitoMessageRef.known?(channel, 'missed')).to be(true)
  end

  it 'reads past a known webhook message to find older gaps' do
    channel.update!(preferences: { avito_cursor: (now - 30.minutes).to_i })
    page = Array.new(100) { |i| avito_message(id: "m#{i}", created: (now - 2.minutes - i.seconds).to_i) }
    AvitoMessageRef.claim!(channel, 'chat-1', 'm0')
    chat = avito_chat.merge('last_message' => page.first)
    stub_avito(:get, "/messenger/v2/accounts/#{account}/chats", body: { chats: [chat] })
    messages_url = "https://api.avito.ru/messenger/v3/accounts/#{account}/chats/chat-1/messages/"
    stub_request(:get, messages_url).with(query: { limit: 100, offset: 0 })
      .to_return(status: 200, body: page.to_json)
    stub_request(:get, messages_url).with(query: { limit: 100, offset: 100 })
      .to_return(status: 200, body: [avito_message(id: 'older-gap', created: (now - 4.minutes).to_i)].to_json)
    AvitoChannel::Sync.new(channel, now: now).run
    expect(AvitoMessageRef.known?(channel, 'older-gap')).to be(true)
  end

  it 'keeps the chat mapping when an agent corrects the ticket customer' do
    first = ingest('first')
    first.ticket.update!(customer: create(:customer))
    second = ingest('second')
    expect(second.ticket_id).to eq(first.ticket_id)
  end

  it 'treats a custom closed state as closed' do
    first = ingest('first')
    custom = create(:ticket_state, name: 'Resolved custom', state_type: Ticket::StateType.lookup(name: 'closed'))
    first.ticket.update!(state: custom)
    second = ingest('second')
    expect(second.ticket_id).not_to eq(first.ticket_id)
  end

  it 'does not leave a permanent deduplication claim after an interrupted import' do
    channel
    allow(importer).to receive(:create).and_raise(Interrupt, 'worker terminated')
    expect { ingest('interrupted') }.to raise_error(Interrupt)
    allow(importer).to receive(:create).and_call_original
    expect(ingest('interrupted')).to be_present
  end

  it 'does not replace the account identity behind existing tickets' do
    stub_avito(:post, '/token', body: { access_token: 'other-token', expires_in: 86_400 })
    stub_avito(:get, '/core/v1/accounts/self', body: { id: 987, name: 'Other account' })
    expect { AvitoChannel::Account.save!({ client_id: 'other', client_secret: 'secret' }, channel) }
      .to raise_error(AvitoChannel::Account::Invalid)
  end

  it 'does not report an old webhook subscription as current after its URL changes' do
    channel.options[:webhook_base_url] = 'https://old.example'
    channel.options[:webhook] = { subscribed_at: now.iso8601, url: AvitoChannel::Account.webhook_url(channel) }
    channel.save!
    expect(channel.options.dig(:webhook, :url)).to eq(AvitoChannel::Account.webhook_url(channel))
    stub_avito(:post, '/token', body: { access_token: 'new-token', expires_in: 86_400 })
    stub_avito(:get, '/core/v1/accounts/self', body: { id: account, name: 'Shop' })
    AvitoChannel::Account.save!({ webhook_base_url: 'https://new.example' }, channel)
    subscribed = channel.reload.options[:webhook]
    expect(subscribed[:subscribed_at].present? && subscribed[:url] != AvitoChannel::Account.webhook_url(channel)).to be(false)
  end

  # Review, 2026-10-21: after the fourth 429 retry_on retried on its own: seven sends, four final notes.
  it 'gives a rate-limited delivery four runs in all, each after Avito\'s delay, and one note', performs_jobs: true do
    ticket  = ingest('first').ticket
    article = agent_reply(ticket)
    clear_jobs
    send_url = "https://api.avito.ru/messenger/v1/accounts/#{account}/chats/chat-1/messages"
    stub_request(:post, send_url).to_return(status: 429, body: { message: 'rate limit' }.to_json, headers: { 'Retry-After' => '900' })
    stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-1/messages/", body: [])

    freeze_time do
      expect { CommunicateAvitoJob.perform_now(article.id) }.to have_enqueued_job(CommunicateAvitoJob).at(15.minutes.from_now)
      2.times do
        expect { perform_enqueued_jobs(only: CommunicateAvitoJob) }.to have_enqueued_job(CommunicateAvitoJob).at(15.minutes.from_now)
      end
      expect { perform_enqueued_jobs(only: CommunicateAvitoJob) }.not_to have_enqueued_job(CommunicateAvitoJob)
    end

    expect(a_request(:post, send_url)).to have_been_made.times(4)
    expect(ticket.reload.articles.count { |a| a.body.start_with?('Unable to send Avito message') }).to eq(1)
    expect(article.reload.preferences['delivery_status']).to eq('fail')
  end

  it 'retries a webhook import Avito rate-limits after Avito\'s delay, and leaves it to the poll after four runs', performs_jobs: true do
    value = avito_message(id: 'm-limited', chat_id: 'chat-1')
    stub_request(:get, "https://api.avito.ru/messenger/v2/accounts/#{account}/chats/chat-1")
      .to_return(status: 429, body: { message: 'rate limit' }.to_json, headers: { 'Retry-After' => '300' })

    freeze_time do
      expect { AvitoImportJob.perform_now(channel.id, value) }.to have_enqueued_job(AvitoImportJob).at(5.minutes.from_now)
      2.times { perform_enqueued_jobs(only: AvitoImportJob) }
      expect { perform_enqueued_jobs(only: AvitoImportJob) }.not_to raise_error
    end
    expect(enqueued_jobs.count { |job| job['job_class'] == 'AvitoImportJob' }).to eq(0)
    expect(AvitoMessageRef.known?(channel, 'm-limited')).to be(false)
  end

  it 'honors Retry-After when scheduling a delivery retry', performs_jobs: true do
    article = agent_reply(ingest('first').ticket)
    stub_avito(:post, "/messenger/v1/accounts/#{account}/chats/chat-1/messages", status: 429,
                body: { message: 'rate limit' }, headers: { 'Retry-After' => '900' })
    freeze_time do
      expect { CommunicateAvitoJob.perform_now(article.id) }
        .to have_enqueued_job(CommunicateAvitoJob).at(15.minutes.from_now)
    end
  end

  context 'with an image whose send answer was lost' do
    let(:article) { agent_reply(ingest('first').ticket) }
    let(:client)  { instance_double(AvitoMessenger::Client) }
    let(:upload)  { AvitoMessenger::Client::UploadedImage.new(id: 'upload-1', urls: ['https://img.example/upload-1-640.jpg']) }

    def own_image(id, url)
      AvitoMessenger::Message.from_hash(avito_message(id: id, author_id: account, type: 'image',
                                                      content: { 'image' => { 'sizes' => { '640x480' => url } } }))
    end

    before do
      create(:store, object: 'Ticket::Article', o_id: article.id, data: 'PNG', filename: 'photo.png',
                     preferences: { 'Content-Type' => 'image/png' })
      allow(client).to receive_messages(send_text: AvitoMessenger::Message.from_hash(avito_message(id: 'accepted-text', author_id: account)),
                                        upload_image: upload, mark_read: nil)
      allow(client).to receive(:send_image).and_raise(AvitoMessenger::Error::Network, 'lost response')
      begin
        AvitoChannel::Delivery.new(article, client: client).deliver!
      rescue AvitoMessenger::Error::Network
        nil # the send whose answer was lost
      end
    end

    it 'finds the image by its upload\'s address instead of sending it again' do
      sent = own_image('accepted-image', 'https://img.example/upload-1-640.jpg')
      allow(client).to receive(:messages).and_return([sent])

      AvitoChannel::Delivery.new(article.reload, client: client).deliver!

      expect(client).to have_received(:send_image).once
      expect(article.reload.preferences.dig('avito', 'pieces', 1, 'message_id')).to eq('accepted-image')
    end

    # Review, 2026-10-21: a manager's picture sent in Avito after the failed send was taken for the reply.
    it 'does not take a manager\'s picture for it, and asks the agent to look instead of guessing' do
      allow(client).to receive(:messages).and_return([own_image('manager-image', 'https://img.example/manager.jpg')])

      expect { AvitoChannel::Delivery.new(article.reload, client: client).deliver! }
        .to raise_error(AvitoChannel::Delivery::Undeliverable, include('photo.png', 'Look at the chat in Avito'))
      expect(client).to have_received(:send_image).once
      expect(article.reload.preferences.dig('avito', 'pieces', 1, 'message_id')).to be_nil
    end
  end

  it 'sends an image again when Avito answered its send with an error' do
    article = agent_reply(ingest('first').ticket)
    create(:store, object: 'Ticket::Article', o_id: article.id, data: 'PNG', filename: 'photo.png',
                   preferences: { 'Content-Type' => 'image/png' })
    client = instance_double(AvitoMessenger::Client, mark_read: nil, messages: [],
                                                     send_text: AvitoMessenger::Message.from_hash(avito_message(id: 'text-ok', author_id: account)),
                                                     upload_image: AvitoMessenger::Client::UploadedImage.new(id: 'upload-1', urls: []))
    allow(client).to receive(:send_image).and_raise(AvitoMessenger::Error::Api.new('HTTP 500', status: 500))
    expect { AvitoChannel::Delivery.new(article, client: client).deliver! }.to raise_error(AvitoMessenger::Error::Api)

    allow(client).to receive(:send_image).and_return(AvitoMessenger::Message.from_hash(avito_message(id: 'img-ok', author_id: account, type: 'image')))
    AvitoChannel::Delivery.new(article.reload, client: client).deliver!
    expect(article.reload.preferences.dig('avito', 'pieces', 1, 'message_id')).to eq('img-ok')
  end

  describe 'tickets merged across chats' do
    let(:send_url) { ->(chat) { "https://api.avito.ru/messenger/v1/accounts/#{account}/chats/#{chat}/messages" } }
    let(:first)    { ingest('a1', chat_id: 'chat-1') }
    let(:second)   { ingest('b1', chat_id: 'chat-2', author_id: 555, text: 'Другой покупатель') }

    before do
      stub_avito_chat(avito_chat(id: 'chat-2', buyer_id: 555, buyer_name: 'Пётр'))
      second.ticket.merge_to(ticket_id: first.ticket_id, user_id: 1)
      %w[chat-1 chat-2].each do |chat|
        stub_request(:post, send_url.call(chat)).to_return(
          status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { id: "sent-#{chat}", created: Time.zone.now.to_i, direction: 'out', type: 'text', content: { text: 'x' } }.to_json,
        )
        stub_avito(:post, "/messenger/v1/accounts/#{account}/chats/#{chat}/read", body: { ok: true })
      end
    end

    # Review, 2026-10-21: the answer to the merged chat's buyer went to the other buyer's chat.
    it 'answers a message in the chat it came from' do
      article = agent_reply(first.ticket.reload, in_reply_to: second.reload.message_id)

      AvitoChannel::Delivery.new(article).deliver!

      expect(a_request(:post, send_url.call('chat-2'))).to have_been_made.once
      expect(a_request(:post, send_url.call('chat-1'))).not_to have_been_made
      expect(article.reload.preferences['avito']).to include('chat_id' => 'chat-2', 'channel_id' => channel.id)
    end

    it 'sends nothing when the reply does not say which chat it is for' do
      article = agent_reply(first.ticket.reload)

      expect { AvitoChannel::Delivery.new(article).deliver! }
        .to raise_error(AvitoChannel::Delivery::Undeliverable, include('several Avito chats'))
      expect(a_request(:post, %r{/messages\z})).not_to have_been_made
    end

    it 'finishes a retry in the chat its first attempt went to' do
      article = agent_reply(first.ticket.reload, preferences: { 'avito' => { 'channel_id' => channel.id, 'chat_id' => 'chat-2' } })

      AvitoChannel::Delivery.new(article).deliver!

      expect(a_request(:post, send_url.call('chat-2'))).to have_been_made.once
    end
  end

  it 'does not mistake a message written before a failed send attempt for successful delivery' do
    article = agent_reply(ingest('first').ticket)
    client = instance_double(AvitoMessenger::Client)
    allow(client).to receive(:send_text).and_raise(AvitoMessenger::Error::Network, 'connect failed; nothing sent')
    expect { AvitoChannel::Delivery.new(article, client: client).deliver! }.to raise_error(AvitoMessenger::Error::Network)
    attempted = article.reload.preferences.dig('avito', 'pieces', 0, 'attempted_at')
    old = AvitoMessenger::Message.from_hash(avito_message(id: 'old-own', author_id: account, text: 'Reply', created: attempted - 300))
    fresh = AvitoMessenger::Message.from_hash(avito_message(id: 'new-own', author_id: account, text: 'Reply', created: attempted + 120))
    allow(client).to receive(:messages).and_return([old])
    allow(client).to receive(:send_text).and_return(fresh)
    allow(client).to receive(:mark_read)
    AvitoChannel::Delivery.new(article.reload, client: client).deliver!
    expect(client).to have_received(:send_text).twice
    expect(article.reload.preferences.dig('avito', 'pieces', 0, 'message_id')).to eq('new-own')
  end
end
