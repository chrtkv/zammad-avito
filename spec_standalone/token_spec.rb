RSpec.describe AvitoMessenger::Token do
  let(:now) { Time.utc(2026, 10, 20, 12, 0, 0) }

  it 'is usable until the refresh margin before expiry' do
    expect(described_class.new(access_token: 't', expires_at: now + 301).usable?(now)).to be(true)
    expect(described_class.new(access_token: 't', expires_at: now + 300).usable?(now)).to be(false)
    expect(described_class.new(access_token: '', expires_at: now + 3600).usable?(now)).to be(false)
  end

  it 'round-trips through the hash stored in the channel' do
    token = described_class.new(access_token: 't', expires_at: now + 3600)
    restored = described_class.from_h(token.to_h)
    expect([restored.access_token, restored.expires_at]).to eq(['t', now + 3600])
  end

  it 'restores nothing from an empty or partial hash' do
    expect(described_class.from_h(nil)).to be_nil
    expect(described_class.from_h({ 'access_token' => 't' })).to be_nil
  end
end
