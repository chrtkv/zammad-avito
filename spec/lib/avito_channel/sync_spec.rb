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
    expect(sync.run).to eq(chats: 0, imported: 0, unavailable: 0)
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

      expect(sync.run).to eq(chats: 1, imported: 2, unavailable: 0)

      articles = Ticket::Article.where(message_id: ["avito.#{account}.chat-1.m1", "avito.#{account}.chat-1.m2"]).order(:created_at)
      expect(articles.first.ticket.preferences.dig(:avito, :chat_type)).to be_nil # 'chat-1' carries no type
      expect(articles.map { |a| [a.body, a.sender.name] }).to eq([%w[Вопрос Customer], ['Ответ из Авито', 'Agent']])
      expect(channel.reload.preferences[:avito_cursor]).to eq((now - 60).to_i)
      expect(a_request(:get, %r{/chats/old/messages})).not_to have_been_made
    end

    it 'skips messages it already has' do
      AvitoMessageRef.claim!(channel, 'chat-1', 'm1')
      stub_chats(avito_chat(updated: (now - 5.minutes).to_i))
      stub_messages('chat-1', [list_message('m1', created: now - 6.minutes)])

      expect(sync.run).to eq(chats: 1, imported: 0, unavailable: 0)
    end

    # A chat is never put off whole: that let the cursor pass its older missed messages (review, 2026-10-21).
    it 'reads a chat changed in the last minute now, holding back only own messages that young' do
      stub_chats(avito_chat(updated: (now - 10.seconds).to_i))
      stub_messages('chat-1', [
                      list_message('own-new', created: now - 10.seconds, author_id: account, text: 'Только что'),
                      list_message('customer-new', created: now - 20.seconds, text: 'Вопрос'),
                    ])

      expect(sync.run).to eq(chats: 1, imported: 1, unavailable: 0)
      expect(AvitoMessageRef.known?(channel, 'customer-new')).to be(true)
      expect(AvitoMessageRef.known?(channel, 'own-new')).to be(false)
      expect(channel.reload.preferences[:avito_cursor]).to be < (now - 10.seconds).to_i

      later = described_class.new(channel, now: now + 2.minutes)
      expect(later.run).to include(imported: 1)
      expect(AvitoMessageRef.known?(channel, 'own-new')).to be(true)
    end

    # Seen on the live account on 2026-10-20: no chat had changed within the backfill day.
    it 'moves the cursor on when nothing changed, so the next poll does not scan the backfill again' do
      channel.update!(preferences: {})
      channel.options[:sync] = { backfill_days: 1, poll_interval: 60 }
      channel.save!
      stub_chats(avito_chat(updated: (now - 23.days).to_i))

      expect(sync.run).to eq(chats: 0, imported: 0, unavailable: 0)
      expect(channel.reload.preferences[:avito_cursor]).to eq((now - 60).to_i)
    end

    # Seen on the live API on 2026-10-20: with the subscription paid, some chats still answer 402.
    it 'skips a chat the subscription does not cover and goes on with the others' do
      covered   = avito_chat(id: 'chat-1', updated: (now - 5.minutes).to_i)
      uncovered = avito_chat(id: 'chat-2', updated: (now - 4.minutes).to_i)
      stub_chats(covered, uncovered)
      stub_messages('chat-1', [list_message('m1', created: now - 5.minutes)])
      stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-2/messages/", status: 402,
                                                                                  body: { code: 402, message: 'Перейдите на подписку с API мессенджера' })

      expect(sync.run).to eq(chats: 2, imported: 1, unavailable: 1)
      expect(channel.reload.preferences[:avito_cursor]).to eq((now - 60).to_i)
    end

    context 'when a chat is not covered and the list carries its last message' do
      let(:uncovered) do
        avito_chat(id: 'chat-2', updated: (now - 4.minutes).to_i).merge(
          'last_message' => { 'id' => 'last-1', 'author_id' => AvitoChannelSpecHelpers::AVITO_BUYER_ID, 'created' => (now - 4.minutes).to_i,
                              'direction' => 'in', 'type' => 'text', 'content' => { 'text' => 'Ещё продаёте?' } },
        )
      end

      before do
        stub_chats(avito_chat(id: 'chat-1', updated: (now - 5.minutes).to_i), uncovered)
        stub_messages('chat-1', [list_message('m1', created: now - 5.minutes)])
        stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-2/messages/", status: 402,
                                                                                    body: { code: 402, message: 'Перейдите на подписку с API мессенджера' })
      end

      it 'imports that message and flags the ticket once' do
        expect(sync.run).to eq(chats: 2, imported: 2, unavailable: 1)

        article = Ticket::Article.find_by(message_id: "avito.#{account}.chat-2.last-1")
        ticket  = article.ticket
        expect(article.body).to eq('Ещё продаёте?')
        expect(ticket.tag_list).to include('avito-api-unavailable')
        notes = ticket.articles.select { |a| a.preferences.dig('avito', 'notice') == 'uncovered' }
        expect(notes.size).to eq(1)
        expect(notes.first).to have_attributes(internal: true)
        expect(notes.first.body).to include('Read the chat and reply in Avito', 'https://www.avito.ru/item/1')

        channel.update!(preferences: channel.reload.preferences.merge(avito_cursor: (now - 10.minutes).to_i))
        described_class.new(channel, now: now).run
        expect(ticket.reload.articles.count { |a| a.preferences.dig('avito', 'notice') == 'uncovered' }).to eq(1)
      end

      it 'drops the flag once the chat answers again' do
        sync.run
        ticket = Ticket::Article.find_by(message_id: "avito.#{account}.chat-2.last-1").ticket

        stub_messages('chat-2', [list_message('last-1', created: now - 4.minutes)])
        channel.update!(preferences: channel.reload.preferences.merge(avito_cursor: (now - 10.minutes).to_i))
        described_class.new(channel, now: now).run

        expect(ticket.reload.tag_list).not_to include('avito-api-unavailable')
        expect(ticket.preferences.dig(:avito, :uncovered)).to be(false)
      end

      it 'writes the note in the system language' do
        AvitoChannel::Setup.ensure!
        Setting.set('locale_default', 'ru')
        sync.run

        note = Ticket::Article.where(internal: true).detect { |a| a.preferences.dig('avito', 'notice') == 'uncovered' }
        expect(note.body).to start_with('Авито не отдаёт сообщения этого чата через API')
      end
    end

    it 'fails when no chat is covered, so the channel shows the missing subscription' do
      stub_chats(avito_chat(updated: (now - 5.minutes).to_i))
      stub_avito(:get, "/messenger/v3/accounts/#{account}/chats/chat-1/messages/", status: 402,
                                                                                  body: { code: 402, message: 'Перейдите на подписку с API мессенджера' })

      expect { sync.run }.to raise_error(AvitoMessenger::Error::SubscriptionRequired)
    end

    it 'does not import history older than the cursor from a chat that woke up' do
      stub_chats(avito_chat(updated: (now - 5.minutes).to_i))
      stub_messages('chat-1', [
                      list_message('new', created: now - 5.minutes),
                      list_message('ancient', created: now - 30.days),
                    ])

      expect(sync.run).to eq(chats: 1, imported: 1, unavailable: 0)
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
