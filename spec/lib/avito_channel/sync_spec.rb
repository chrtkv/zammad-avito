require 'rails_helper'

RSpec.describe AvitoChannel::Sync, :aggregate_failures do
  let(:channel) { create_avito_channel }
  let(:account) { AvitoChannelSpecHelpers::AVITO_USER_ID }
  let(:now)     { Time.zone.now.change(usec: 0) }
  let(:sync)    { described_class.new(channel, now: now) }

  def stub_chats(*chats)
    stub_avito(:get, "/messenger/v2/accounts/#{account}/chats", body: { chats: chats })
  end

  def stub_messages(chat_id, messages)
    stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/#{chat_id}/messages/", body: messages)
  end

  def list_message(id, created:, author_id: AvitoChannelSpecHelpers::AVITO_BUYER_ID, text: 'текст')
    { id: id, author_id: author_id, created: created.to_i, direction: author_id == account ? 'out' : 'in',
      type: 'text', content: { text: text } }
  end

  it 'starts at "now" on the first run, without importing history' do
    expect(sync.run).to eq(chats: 0, imported: 0)
    expect(channel.reload.preferences[:avito_cursor]).to eq((now - 60).to_i)
    expect(a_request(:get, %r{/chats})).not_to have_been_made
  end

  context 'with a cursor' do
    let(:cursor) { (now - 10.minutes).to_i }

    before { channel.update!(preferences: { avito_cursor: cursor }) }

    it 'imports what the webhook missed, own messages written in Avito included' do
      chat = avito_chat(updated: (now - 5.minutes).to_i)
      stub_chats(chat, avito_chat(id: 'old', updated: cursor - 3600))
      stub_messages('chat-1', [
                      list_message('m2', created: now - 5.minutes, author_id: account, text: 'Ответ из Авито'),
                      list_message('m1', created: now - 6.minutes, text: 'Вопрос'),
                    ])

      expect(sync.run).to eq(chats: 1, imported: 2)

      articles = Ticket::Article.where(message_id: ["avito.#{account}.chat-1.m1", "avito.#{account}.chat-1.m2"]).order(:created_at)
      expect(articles.map { |a| [a.body, a.sender.name] }).to eq([%w[Вопрос Customer], ['Ответ из Авито', 'Agent']])
      expect(channel.reload.preferences[:avito_cursor]).to eq(chat['updated'])
      expect(a_request(:get, %r{/chats/old/messages})).not_to have_been_made
    end

    it 'skips messages it already has' do
      AvitoMessageRef.claim!(channel, 'chat-1', 'm1')
      stub_chats(avito_chat(updated: (now - 5.minutes).to_i))
      stub_messages('chat-1', [list_message('m1', created: now - 6.minutes)])

      expect(sync.run).to eq(chats: 1, imported: 0)
    end

    it 'leaves chats changed in the last minute for the next run' do
      stub_chats(avito_chat(updated: (now - 10.seconds).to_i))

      expect(sync.run).to eq(chats: 0, imported: 0)
      expect(channel.reload.preferences[:avito_cursor]).to eq(cursor)
    end

    it 'does not import history older than the cursor from a chat that woke up' do
      stub_chats(avito_chat(updated: (now - 5.minutes).to_i))
      stub_messages('chat-1', [
                      list_message('new', created: now - 5.minutes),
                      list_message('ancient', created: now - 30.days),
                    ])

      expect(sync.run).to eq(chats: 1, imported: 1)
      expect(AvitoMessageRef.known?(channel, 'ancient')).to be(false)
    end
  end

  describe 'as a Zammad channel' do
    it 'is polled through Channel.fetch at the account\'s interval' do
      driver = Channel::Driver::Avito.new
      expect(driver.fetchable?(channel)).to be(true)

      channel.update!(preferences: { last_fetch: 1.minute.ago })
      expect(driver.fetchable?(channel)).to be(false)

      channel.update!(preferences: { last_fetch: 6.minutes.ago })
      expect(driver.fetchable?(channel)).to be(true)
    end

    it 'shows a missing subscription as the channel\'s error' do
      channel.update!(preferences: { avito_cursor: (now - 10.minutes).to_i })
      stub_avito(:get, "/messenger/v2/accounts/#{account}/chats", status: 402,
                                                                  body: { error: { code: 402, message: 'Перейдите на подписку с API мессенджера' } })

      channel.fetch(true)

      expect(channel.reload.status_in).to eq('error')
      expect(channel.last_log_in).to include('подписку с API мессенджера')
    end

    it 'reports what a poll imported' do
      channel.fetch(true)
      expect(channel.reload).to have_attributes(status_in: 'ok', last_log_in: '0 messages from 0 chats')
    end
  end
end
