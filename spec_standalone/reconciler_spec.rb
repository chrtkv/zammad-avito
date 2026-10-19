RSpec.describe AvitoMessenger::Reconciler do
  def chat(id, updated)
    { 'id' => id, 'updated' => updated }
  end

  def message(id, created)
    AvitoMessenger::Message.from_hash({ 'id' => id, 'created' => created, 'type' => 'text' }, account_user_id: 1)
  end

  describe '.chats_to_sync' do
    it 'takes chats changed at or after the cursor, oldest change first' do
      chats = [chat('c', 300), chat('a', 100), chat('b', 200), chat('d', 200)]
      expect(described_class.chats_to_sync(chats, cursor: 200).map { |c| c['id'] }).to eq(%w[b d c])
    end

    it 'takes everything on the first run' do
      expect(described_class.chats_to_sync([chat('a', 5), chat('a', 5)], cursor: nil).size).to eq(1)
    end
  end

  describe '.more_chats?' do
    let(:full_page) { Array.new(100) { |i| chat("c#{i}", 1000 + i) } }

    it 'stops at a short page' do
      expect(described_class.more_chats?(full_page.first(99), cursor: nil, offset: 0)).to be(false)
    end

    it 'stops at the documented offset cap' do
      expect(described_class.more_chats?(full_page, cursor: nil, offset: 900)).to be(true)
      expect(described_class.more_chats?(full_page, cursor: nil, offset: 1000)).to be(false)
    end

    it 'stops once a whole page is older than the cursor' do
      expect(described_class.more_chats?(full_page, cursor: 1099, offset: 0)).to be(true)
      expect(described_class.more_chats?(full_page, cursor: 1100, offset: 0)).to be(false)
    end
  end

  describe '.missing_messages' do
    it 'returns unknown messages once each, oldest first' do
      messages = [message('m3', 300), message('m2', 200), message('m1', 100), message('m3', 300)]
      expect(described_class.missing_messages(messages, known_ids: ['m2']).map(&:id)).to eq(%w[m1 m3])
    end
  end

  describe '.more_messages?' do
    let(:page) { Array.new(100) { |i| message("m#{i}", 1000 - i) } }

    it 'reads on through a page of new messages' do
      expect(described_class.more_messages?(page, known_ids: [], offset: 0)).to be(true)
    end

    it 'stops at a message already imported' do
      expect(described_class.more_messages?(page, known_ids: ['m50'], offset: 0)).to be(false)
    end

    it 'stops past the backfill horizon' do
      expect(described_class.more_messages?(page, known_ids: [], offset: 0, since: Time.at(950).utc)).to be(false)
    end
  end
end
