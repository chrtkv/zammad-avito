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

  it 'ignores replies outside the window' do
    late = message(author_id: account, text: 'Да, в наличии.', created: sent_at + 3600)
    expect(described_class.match(late, sent)).to be_nil
  end
end
