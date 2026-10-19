RSpec.describe AvitoMessenger::WebhookEvent do
  let(:body) { fixture('webhook_text') }

  it 'parses a message delivery' do
    event = described_class.parse(body.to_json)

    expect(event).to have_attributes(payload_type: 'message', account_user_id: 12_345_678, message?: true)
    expect(event.message).to have_attributes(
      id:              'a1b2c3d4e5f60718293a4b5c6d7e8f90',
      chat_id:         'u2i-AbCdEfGhIjKlMnOpQrStUv',
      chat_type:       'u2i',
      item_id:         1_234_567_890,
      text:            'Здравствуйте! Ещё в наличии?',
      origin:          :customer,
      created_at:      Time.at(1_760_899_990).utc,
    )
  end

  it 'recognises the account a delivery belongs to' do
    event = described_class.parse(body)
    expect(event.for_account?(12_345_678)).to be(true)
    expect(event.for_account?('12345678')).to be(true)
    expect(event.for_account?(1)).to be(false)
  end

  it 'sees an own message as own' do
    body['payload']['value']['author_id'] = 12_345_678
    expect(described_class.parse(body).message.own?).to be(true)
  end

  it 'treats {} as Avito checking the URL' do
    expect(described_class.probe?({})).to be(true)
    expect(described_class.probe?(body)).to be(false)
  end

  it 'keeps an unknown event type without a message' do
    body['payload'] = { 'type' => 'chat_read', 'value' => { 'user_id' => 12_345_678 } }
    expect(described_class.parse(body)).to have_attributes(message?: false, payload_type: 'chat_read')
  end

  it 'rejects bodies that are not a delivery' do
    expect { described_class.parse('not json') }.to raise_error(AvitoMessenger::Error::BadPayload)
    expect { described_class.parse('[]') }.to raise_error(AvitoMessenger::Error::BadPayload)
    expect { described_class.parse({ 'payload' => { 'type' => 'message' } }) }
      .to raise_error(AvitoMessenger::Error::BadPayload, /without a message/)
  end
end
