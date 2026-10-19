require 'net/http'
require 'openssl'
require 'uri'

module AvitoMessenger
  # Minimal HTTP transport over Net::HTTP. Anything answering #call with the same signature can replace it:
  # the specs pass a fake, and the Zammad glue may pass one that honours the system's proxy settings.
  class Transport
    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    NETWORK_ERRORS = [
      SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    ].freeze

    def initialize(open_timeout: 5, read_timeout: 20)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Header names in the response are lower-case.
    def call(method, url, headers: {}, body: nil)
      uri     = URI(url)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                                     open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(request)
      end

      Response.new(status: response.code.to_i, headers: response.each_header.to_h, body: response.body.to_s)
    rescue *NETWORK_ERRORS => e
      raise Error::Network, "#{e.class}: #{e.message}"
    end
  end
end
