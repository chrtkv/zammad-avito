RSpec.describe AvitoMessenger::Echo do
  let(:account) { 12_345_678 }
  let(:sent_at) { Time.utc(2026, 10, 20, 12, 0, 0) }
  let(:sent)    { [{ article_id: 42, chat_id: 'c1', text: "Да,  в наличии.\n", sent_at: }] }

  def message(author_id:, text:, created: sent_at + 2, chat_id: 'c1', type: 'text')
    AvitoMessenger::Message.from_hash(
      { 'id' => 'x', 'author_id' => author_id, 'type' => type, 'content' => { 'text' => text }, 'created' => created.to_i },
      account_user_id: account, chat_id:,
    )
  end

  it 'links an own message to the reply Zammad just sent with the same text' do
    expect(described_class.match(message(author_id: account, text: 'Да, в наличии.'), sent)).to eq(42)
  end

  it 'leaves a manager\'s own message written in Avito alone' do
    expect(described_class.match(message(author_id: account, text: 'Другой текст'), sent)).to be_nil
  end

  it 'never takes a customer\'s message for an echo' do
    expect(described_class.match(message(author_id: 1, text: 'Да, в наличии.'), sent)).to be_nil
  end

  it 'requires the same chat' do
    expect(described_class.match(message(author_id: account, text: 'Да, в наличии.', chat_id: 'c2'), sent)).to be_nil
  end

  # Review, 2026-10-21: the same text a manager wrote in Avito before the attempt passed for the reply.
  it 'never takes a message written before the attempt for its echo' do
    early = message(author_id: account, text: 'Да, в наличии.', created: sent_at - 300)
    expect(described_class.match(early, sent)).to be_nil
    slightly_behind = message(author_id: account, text: 'Да, в наличии.', created: sent_at - 20)
    expect(described_class.match(slightly_behind, sent)).to eq(42)
  end

  it 'matches an image piece with an own image written after the attempt' do
    image = AvitoMessenger::Message.from_hash(
      { 'id' => 'img', 'author_id' => account, 'type' => 'image', 'content' => {}, 'created' => (sent_at + 5).to_i },
      account_user_id: account, chat_id: 'c1',
    )
    pieces = [{ article_id: 7, chat_id: 'c1', kind: 'image', sent_at: }]
    expect(described_class.match(image, pieces)).to eq(7)
    expect(described_class.match(image, sent)).to be_nil
  end

  it 'ignores replies outside the window' do
    late = message(author_id: account, text: 'Да, в наличии.', created: sent_at + 3600)
    expect(described_class.match(late, sent)).to be_nil
  end
end
