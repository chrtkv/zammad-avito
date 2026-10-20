RSpec.describe AvitoMessenger::Transport do
  let(:transport) { described_class.new }
  let(:ok) do
    instance_double(Net::HTTPResponse, code: '200', body: '{"id":1}').tap do |response|
      allow(response).to receive(:each_header).and_return({ 'content-type' => 'application/json' }.each)
    end
  end

  def connection(started: true)
    instance_double(Net::HTTP, :use_ssl= => nil, :open_timeout= => nil, :read_timeout= => nil,
                               :keep_alive_timeout= => nil, start: nil, started?: started, finish: nil)
  end

  it 'reuses one open connection per host instead of opening one per request' do
    http = connection
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:request).and_return(ok)

    2.times { transport.call(:get, 'https://api.avito.ru/core/v1/accounts/self') }

    expect(Net::HTTP).to have_received(:new).once
    expect(http).to have_received(:request).twice
  end

  # Seen from our server on 2026-10-20: every other connect took 15 s, the first SYNs dropped.
  it 'opens the connection once more when it timed out, and a POST goes out once' do
    stalled = connection
    fresh   = connection
    allow(Net::HTTP).to receive(:new).and_return(stalled, fresh)
    allow(stalled).to receive(:start).and_raise(Net::OpenTimeout)
    allow(fresh).to receive(:request).and_return(ok)

    response = transport.call(:post, 'https://api.avito.ru/messenger/v1/accounts/1/chats/c/messages', body: '{}')

    expect(response.status).to eq(200)
    expect(fresh).to have_received(:request).once
  end

  it 'gives up after the second failed open' do
    stalled = connection
    allow(Net::HTTP).to receive(:new).and_return(stalled)
    allow(stalled).to receive(:start).and_raise(Net::OpenTimeout)

    expect { transport.call(:get, 'https://api.avito.ru/x') }.to raise_error(AvitoMessenger::Error::Network, /OpenTimeout/)
    expect(Net::HTTP).to have_received(:new).twice
  end

  it 'does not repeat a request that failed after it was sent' do
    http = connection
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)

    expect { transport.call(:post, 'https://api.avito.ru/x', body: '{}') }.to raise_error(AvitoMessenger::Error::Network, /ReadTimeout/)
    expect(http).to have_received(:request).once
  end
end
