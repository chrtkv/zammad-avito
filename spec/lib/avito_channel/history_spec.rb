require 'rails_helper'

RSpec.describe AvitoChannel::History, :aggregate_failures do
  let(:channel) { create_avito_channel }
  let(:account) { AvitoChannelSpecHelpers::AVITO_USER_ID }
  let(:now)     { Time.zone.now.change(usec: 0) }

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

  before { Rails.cache.delete("avito-history-#{channel.id}") }

  describe AvitoChannel::History::Batch do
    def state(**overrides)
      { 'run' => 'r1', 'days' => 30, 'since' => (now - 30.days).to_i, 'started_at' => now.to_i, 'phase' => 'walk',
        'offset' => 0, 'chat' => nil, 'page' => 0, 'chats' => 0, 'imported' => 0, 'unavailable' => 0 }.merge(overrides.stringify_keys)
    end

    def batch(from = state)
      described_class.new(channel, from, transport: AvitoMessenger::Transport.new, now: now).run
    end

    def stub_message_page(chat_id, offset, messages)
      stub_request(:get, "https://api.avito.ru/messenger/v3/accounts/#{account}/chats/#{chat_id}/messages/")
        .with(query: { limit: 100, offset: offset })
        .to_return(status: 200, body: messages.to_json, headers: { 'Content-Type' => 'application/json' })
    end

    it 'reads the chats changed since the start date back to it, and leaves the poll\'s cursor alone' do
      channel.update!(preferences: { avito_cursor: (now - 1.minute).to_i })
      stub_chats(avito_chat(updated: (now - 2.days).to_i), avito_chat(id: 'ancient', updated: (now - 40.days).to_i))
      stub_messages('chat-1', [list_message('m2', created: now - 2.days), list_message('m1', created: now - 20.days),
                               list_message('m0', created: now - 31.days)])

      result, requests, through = batch

      expect(result).to include('chats' => 1, 'imported' => 2, 'unavailable' => 0, 'offset' => 1, 'chat' => nil)
      expect([requests, through]).to eq([2, true])
      expect(AvitoMessageRef.known?(channel, 'm0')).to be(false)
      expect(a_request(:get, %r{/chats/ancient/messages})).not_to have_been_made
      expect(channel.reload.preferences[:avito_cursor]).to eq((now - 1.minute).to_i)
    end

    it 'stops at the first chat older than the start date' do
      stub_chats(*(1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.days).to_i) })
      (1..9).each { |n| stub_messages("chat-#{n}", []) }

      first, = batch(state(since: (now - 9.5.days).to_i))
      result, _requests, through = batch(first)
      expect(result).to include('chats' => 9)
      expect(through).to be(true)
      expect(a_request(:get, %r{/chats/chat-10/messages})).not_to have_been_made
    end

    # Review, 2026-10-21: a batch of twenty whole chats made 141 requests in a row on a deep history.
    it 'stops after its budget of requests, inside a chat\'s history, and the next batch reads on from there' do
      stub_const('AvitoChannel::History::BUDGET', 3)
      page = ->(from) { Array.new(100) { |i| list_message("m#{from + i}", created: now - 1.day - (from + i).minutes) } }
      stub_chats(avito_chat(updated: (now - 1.day).to_i), avito_chat(id: 'chat-2', updated: (now - 2.days).to_i))
      stub_message_page('chat-1', 0, page.call(0))
      stub_message_page('chat-1', 100, page.call(100))
      stub_message_page('chat-1', 200, [list_message('m200', created: now - 2.days)])
      stub_messages('chat-2', [])

      first, requests, through = batch
      expect(first).to include('chat' => 'chat-1', 'page' => 200, 'imported' => 200, 'chats' => 1)
      expect([requests, through]).to eq([3, false])

      second, requests, through = batch(first)
      expect(second).to include('offset' => 2, 'chat' => nil, 'imported' => 201, 'chats' => 2)
      expect([requests, through]).to eq([3, true])
      expect(a_request(:get, %r{/messenger/v2/accounts/#{account}/chats\?})).to have_been_made.twice
    end

    it 'stops inside a page when imports use up the budget; the next batch reads the page again' do
      stub_const('AvitoChannel::History::BUDGET', 3)
      sizes = ->(n) { { 'image' => { 'sizes' => { '640x480' => "https://img.example/#{n}.jpg" } } } }
      stub_request(:get, %r{\Ahttps://img\.example/}).to_return(status: 200, body: 'JPEG', headers: { 'Content-Type' => 'image/jpeg' })
      stub_chats(avito_chat(updated: (now - 1.day).to_i))
      stub_messages('chat-1', (1..5).map do |n|
        list_message("i#{n}", created: now - 1.day - n.minutes).merge(type: 'image', content: sizes.call(n))
      end)

      runs = []
      current = state
      loop do
        current, requests, through = batch(current)
        runs << requests
        break if through || runs.size > 10
      end

      expect(runs.max).to be <= 4 # the budget, and the file of the image being imported when it ran out
      expect(current['imported']).to eq(5)
      expect((1..5).all? { |n| AvitoMessageRef.known?(channel, "i#{n}") }).to be(true)
    end

    it 'goes on in the chat it was in by its id, without reading the chat list' do
      stub_message_page('chat-7', 100, [list_message('old', created: now - 3.days)])
      stub_avito_chat(avito_chat(id: 'chat-7'))
      stub_chats

      result, = batch(state(offset: 6, chat: 'chat-7', page: 100))

      expect(a_request(:get, %r{/chats/chat-7/messages/\?limit=100&offset=100})).to have_been_made
      expect(a_request(:get, %r{/messenger/v2/accounts/#{account}/chats\?})).to have_been_made.once # for the next chat
      expect(result).to include('imported' => 1, 'offset' => 7)
    end

    context 'with a chat that already has a ticket' do
      let(:closed) { Ticket::State.find_by(name: 'closed') }
      let!(:ticket) do
        AvitoChannel::Importer.new(channel).tap { |importer| importer.remember_chat(avito_chat) }
          .import(AvitoMessenger::Message.from_hash(list_message('m9', created: now - 1.hour).stringify_keys,
                                                    account_user_id: account, chat_id: 'chat-1')).ticket
      end

      before do
        ticket.update!(state: closed)
        stub_chats(avito_chat(updated: (now - 1.hour).to_i))
      end

      it 'files older messages with it, without reopening it' do
        stub_messages('chat-1', [list_message('m9', created: now - 1.hour), list_message('m1', created: now - 5.days)])

        expect(batch.first).to include('imported' => 1)
        expect(Ticket::Article.find_by(message_id: "avito.#{account}.chat-1.m1").ticket).to eq(ticket)
        expect(ticket.reload.state).to eq(closed)
      end

      it 'treats a newer message it finds as one the poll missed' do
        stub_messages('chat-1', [list_message('m10', created: now - 10.minutes), list_message('m9', created: now - 1.hour)])

        batch
        expect(Ticket::Article.find_by(message_id: "avito.#{account}.chat-1.m10").ticket).not_to eq(ticket)
      end
    end
  end

  describe '.start!', performs_jobs: true do
    it 'refuses a number of days out of range' do
      expect { described_class.start!(channel, days: 0) }.to raise_error(described_class::Invalid)
      expect { described_class.start!(channel, days: 'x') }.to raise_error(described_class::Invalid)
      expect { described_class.start!(channel, days: 366) }.to raise_error(described_class::Invalid)
    end

    it 'queues the first batch and refuses a second load while it runs' do
      expect { described_class.start!(channel, days: 7) }.to have_enqueued_job(AvitoHistoryJob)
      expect(described_class.state(channel)).to include('days' => 7, 'phase' => 'walk', 'offset' => 0, 'chat' => nil)
      expect { described_class.start!(channel, days: 7) }.to raise_error(described_class::Invalid)
    end

    it 'lets a new load start once the last one has stalled' do
      state = described_class.start!(channel, days: 7)
      # travel would clear the cache the state lives in.
      Rails.cache.write("avito-history-#{channel.id}", state.merge('updated_at' => 31.minutes.ago.to_i))

      expect { described_class.start!(channel, days: 7) }.to have_enqueued_job(AvitoHistoryJob)
    end
  end

  describe AvitoHistoryJob, performs_jobs: true do
    it 'walks the chat list in spaced-out batches, sweeps, and reports what it imported' do
      chats = (1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.hours).to_i) }
      stub_chats(*chats)
      chats.each { |chat| stub_messages(chat['id'], [list_message("m-#{chat['id']}", created: Time.zone.at(chat['updated']))]) }

      state = AvitoChannel::History.start!(channel, days: 3)
      expect(described_class).to have_been_enqueued.with(channel.id, state)

      10.times { perform_enqueued_jobs(only: described_class) if enqueued_jobs.any? { |job| job['job_class'] == described_class.name } }

      expect(AvitoChannel::History.state(channel)).to include('chats' => 25, 'imported' => 25, 'unavailable' => 0)
      expect(AvitoChannel::History.state(channel)).not_to have_key('error')
      expect(AvitoChannel::History.state(channel)['finished_at']).to be_present
      expect(AvitoMessageRef.where(channel_id: channel.id).count).to eq(25)
      expect(a_request(:get, %r{/messenger/v2/accounts/#{account}/chats\?})).to have_been_made.times(4)
    end

    it 'waits before the next batch in proportion to the requests the last one made' do
      chats = (1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.hours).to_i) }
      stub_chats(*chats)
      chats.each { |chat| stub_messages(chat['id'], []) }
      state = AvitoChannel::History.start!(channel, days: 3)
      clear_enqueued_jobs

      freeze_time do
        expect { described_class.perform_now(channel.id, state) }
          .to have_enqueued_job(described_class).at((AvitoChannel::History::BUDGET * AvitoChannel::History::PACE).seconds.from_now)
      end
    end

    it 'stops a load replaced by a newer one' do
      state = AvitoChannel::History.start!(channel, days: 3)
      Rails.cache.write("avito-history-#{channel.id}", state.merge('updated_at' => 31.minutes.ago.to_i))
      AvitoChannel::History.start!(channel, days: 5)

      described_class.perform_now(channel.id, state)

      expect(a_request(:get, %r{/chats})).not_to have_been_made
    end

    it 'stops for a disabled account and says why' do
      state = AvitoChannel::History.start!(channel, days: 3)
      channel.update!(active: false)

      described_class.perform_now(channel.id, state)

      expect(AvitoChannel::History.state(channel)).to include('error' => 'The Avito account is disabled.')
      expect(a_request(:get, %r{/chats})).not_to have_been_made
    end
  end
end
