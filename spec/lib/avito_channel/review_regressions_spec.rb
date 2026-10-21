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

  it 'honors Retry-After when scheduling a delivery retry', performs_jobs: true do
    article = agent_reply(ingest('first').ticket)
    stub_avito(:post, "/messenger/v1/accounts/#{account}/chats/chat-1/messages", status: 429,
                body: { message: 'rate limit' }, headers: { 'Retry-After' => '900' })
    freeze_time do
      expect { CommunicateAvitoJob.perform_now(article.id) }
        .to have_enqueued_job(CommunicateAvitoJob).at(15.minutes.from_now)
    end
  end

  it 'does not resend an image after the send succeeded but its response was lost' do
    article = agent_reply(ingest('first').ticket)
    create(:store, object: 'Ticket::Article', o_id: article.id, data: 'PNG', filename: 'photo.png',
                   preferences: { 'Content-Type' => 'image/png' })
    client = instance_double(AvitoMessenger::Client)
    text = AvitoMessenger::Message.from_hash(avito_message(id: 'accepted-text', author_id: account))
    allow(client).to receive(:send_text).and_return(text)
    allow(client).to receive(:upload_image).and_return('upload-1')
    allow(client).to receive(:send_image).and_raise(AvitoMessenger::Error::Network, 'lost response')
    expect { AvitoChannel::Delivery.new(article, client: client).deliver! }.to raise_error(AvitoMessenger::Error::Network)
    sent = AvitoMessenger::Message.from_hash(avito_message(id: 'accepted-image', author_id: account, type: 'image'))
    allow(client).to receive(:messages).and_return([sent])
    allow(client).to receive(:send_image).and_return(sent)
    allow(client).to receive(:mark_read)
    AvitoChannel::Delivery.new(article.reload, client: client).deliver!
    expect(client).to have_received(:send_image).once
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
