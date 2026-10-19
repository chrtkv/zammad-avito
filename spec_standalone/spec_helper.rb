# Specs for lib/avito_messenger without Zammad: plain Ruby, a fake transport instead of the network.
# Run with bin/test.

require 'json'

LIB = File.expand_path('../lib', __dir__)
%w[
  avito_messenger
  avito_messenger/error
  avito_messenger/token
  avito_messenger/transport
  avito_messenger/message
  avito_messenger/client
  avito_messenger/webhook_event
  avito_messenger/text_splitter
  avito_messenger/reconciler
  avito_messenger/echo
].each { |file| require File.join(LIB, file) }

# Records requests and answers them from a queue of [status, body, headers].
class FakeTransport
  Request = Struct.new(:method, :url, :headers, :body, keyword_init: true) do
    def path
      URI(url).path
    end

    def query_pairs
      URI.decode_www_form(URI(url).query.to_s)
    end

    def json
      JSON.parse(body)
    end
  end

  attr_reader :requests

  def initialize(*responses)
    @responses = responses
    @requests  = []
  end

  def call(method, url, headers: {}, body: nil)
    @requests << Request.new(method:, url:, headers:, body:)
    raise "unexpected request #{method.upcase} #{url}" if @responses.empty?

    status, body, headers = @responses.shift
    body = JSON.generate(body) if !body.is_a?(String)
    AvitoMessenger::Transport::Response.new(status:, body:, headers: headers || {})
  end
end

module Fixtures
  def fixture(name)
    JSON.parse(File.read(File.join(__dir__, 'fixtures', "#{name}.json")))
  end
end

RSpec.configure do |config|
  config.include Fixtures
  config.disable_monkey_patching!
  config.order = :random
end
