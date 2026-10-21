RSpec.describe AvitoMessenger::Message do
  let(:account) { 12_345_678 }

  def message(attributes)
    described_class.from_hash({ 'id' => 'm1' }.merge(attributes), account_user_id: account, chat_id: 'c1')
  end

  describe '#origin' do
    it 'is the customer when someone else wrote it' do
      expect(message('author_id' => 1, 'type' => 'text').origin).to eq(:customer)
    end

    it 'is our own when the account wrote it, whatever the direction says' do
      expect(message('author_id' => account, 'direction' => 'in', 'type' => 'text').origin).to eq(:own)
    end

    it 'falls back to the direction when there is no author (a send answer)' do
      expect(message('direction' => 'out', 'type' => 'text').origin).to eq(:own)
      expect(message('direction' => 'in', 'type' => 'text').origin).to eq(:customer)
    end

    it 'is system for Avito notices, even when they carry an author' do
      expect(message('author_id' => account, 'type' => 'system').origin).to eq(:system)
    end
  end

  it 'takes the account from a webhook value over the argument' do
    parsed = described_class.from_hash({ 'id' => 'm1', 'user_id' => 7, 'author_id' => 7 }, account_user_id: account)
    expect(parsed).to have_attributes(account_user_id: 7, own?: true)
  end

  it 'refuses a message without an id' do
    expect { described_class.from_hash({ 'type' => 'text' }) }.to raise_error(AvitoMessenger::Error::BadPayload)
  end

  it 'picks the largest image size' do
    sizes = { '140x105' => 'small', '1280x960' => 'large', '640x480' => 'medium' }
    expect(message('type' => 'image', 'content' => { 'image' => { 'sizes' => sizes } }).image_url).to eq('large')
  end

  it 'lists every image size\'s address' do
    sizes = { '140x105' => 'small', '1280x960' => 'large' }
    expect(message('type' => 'image', 'content' => { 'image' => { 'sizes' => sizes } }).image_urls).to eq(%w[small large])
    expect(message('type' => 'text', 'content' => { 'text' => 'x' }).image_urls).to eq([])
  end

  describe '#render_text' do
    it 'keeps text' do
      expect(message('type' => 'text', 'content' => { 'text' => 'Привет' }).render_text).to eq('Привет')
    end

    it 'leaves the body of images and voice empty: they travel as attachments' do
      expect(message('type' => 'image', 'content' => {}).render_text).to eq('')
      expect(message('type' => 'voice', 'content' => { 'voice' => { 'voice_id' => 'v1' } }).render_text).to eq('')
    end

    it 'spells out an item' do
      item = { 'title' => 'Велосипед', 'price_string' => '5 000 ₽', 'item_url' => 'https://avito.ru/1' }
      expect(message('type' => 'item', 'content' => { 'item' => item }).render_text)
        .to eq("Велосипед\n5 000 ₽\nhttps://avito.ru/1")
    end

    it 'does not repeat a URL the link text already shows' do
      link = { 'text' => 'see https://ex.ru/a', 'url' => 'https://ex.ru/a' }
      expect(message('type' => 'link', 'content' => { 'link' => link }).render_text).to eq('see https://ex.ru/a')
    end

    it 'spells out a location' do
      location = { 'title' => 'Офис', 'text' => 'Москва, Тверская 1', 'lat' => 55.75, 'lon' => 37.61 }
      expect(message('type' => 'location', 'content' => { 'location' => location }).render_text)
        .to eq("Офис\nМосква, Тверская 1\n55.75, 37.61")
    end

    it 'names types Avito sends without content, using the given labels' do
      labels = described_class::LABELS.merge(unsupported: 'Сообщение «%s» недоступно')
      expect(message('type' => 'video').render_text(labels)).to eq('Сообщение «video» недоступно')
      expect(message('type' => 'call').render_text).to eq('Missed call')
    end
  end

  it 'parses a quoted message' do
    quoted = message('type' => 'text', 'quote' => { 'id' => 'q1', 'author_id' => account, 'type' => 'text' })
    expect(quoted.quote).to have_attributes(id: 'q1', own?: true, chat_id: 'c1')
  end
end
