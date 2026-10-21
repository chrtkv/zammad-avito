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

  describe 'AvitoChannel::Sync#history' do
    let(:sync) { AvitoChannel::Sync.new(channel, now: now) }

    it 'reads the chats changed since `since` back to it, and leaves the poll\'s cursor alone' do
      channel.update!(preferences: { avito_cursor: (now - 1.minute).to_i })
      stub_chats(avito_chat(updated: (now - 2.days).to_i), avito_chat(id: 'ancient', updated: (now - 40.days).to_i))
      stub_messages('chat-1', [list_message('m2', created: now - 2.days), list_message('m1', created: now - 20.days),
                               list_message('m0', created: now - 31.days)])

      result = sync.history(since: now - 30.days, cursor: (now - 30.days).to_i, offset: 0, limit: 20)

      expect(result).to eq(chats: 1, imported: 2, unavailable: 0, requests: 2, more: false)
      expect(AvitoMessageRef.known?(channel, 'm0')).to be(false)
      expect(a_request(:get, %r{/chats/ancient/messages})).not_to have_been_made
      expect(channel.reload.preferences[:avito_cursor]).to eq((now - 1.minute).to_i)
    end

    it 'cuts its batch out of a page of the chat list' do
      chats = (1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.hours).to_i) }
      stub_chats(*chats)
      chats.each { |chat| stub_messages(chat['id'], []) }

      first  = sync.history(since: now - 30.days, cursor: (now - 30.days).to_i, offset: 0, limit: 20)
      second = sync.history(since: now - 30.days, cursor: (now - 30.days).to_i, offset: 20, limit: 20)

      expect(first).to include(chats: 20, more: true)
      expect(second).to include(chats: 5, more: false)
      expect(a_request(:get, %r{/chats/chat-21/messages})).to have_been_made.once
      expect(a_request(:get, %r{/messenger/v2/accounts/#{account}/chats\?.*offset=0})).to have_been_made.twice
    end

    it 'stops at the first chat older than `since`' do
      stub_chats(*(1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.days).to_i) })
      (1..9).each { |n| stub_messages("chat-#{n}", []) }

      expect(sync.history(since: now - 9.5.days, cursor: (now - 9.5.days).to_i, offset: 0, limit: 20))
        .to include(chats: 9, more: false)
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

        expect(sync.history(since: now - 30.days, cursor: (now - 30.days).to_i, offset: 0, limit: 20)).to include(imported: 1)
        expect(Ticket::Article.find_by(message_id: "avito.#{account}.chat-1.m1").ticket).to eq(ticket)
        expect(ticket.reload.state).to eq(closed)
      end

      it 'treats a newer message it finds as one the poll missed' do
        stub_messages('chat-1', [list_message('m10', created: now - 10.minutes), list_message('m9', created: now - 1.hour)])

        sync.history(since: now - 30.days, cursor: (now - 30.days).to_i, offset: 0, limit: 20)
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
      expect(described_class.state(channel)).to include('days' => 7, 'phase' => 'walk', 'offset' => 0)
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
      expect(a_request(:get, %r{/messenger/v2/accounts/#{account}/chats\?})).to have_been_made.times(3)
    end

    it 'waits before the next batch in proportion to the requests the last one made' do
      chats = (1..25).map { |n| avito_chat(id: "chat-#{n}", updated: (now - n.hours).to_i) }
      stub_chats(*chats)
      chats.each { |chat| stub_messages(chat['id'], []) }
      state = AvitoChannel::History.start!(channel, days: 3)
      clear_enqueued_jobs

      freeze_time do
        expect { described_class.perform_now(channel.id, state) }
          .to have_enqueued_job(described_class).at((21 * AvitoChannel::History::PACE).seconds.from_now)
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
