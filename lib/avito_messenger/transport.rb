require 'net/http'
require 'openssl'
require 'uri'

module AvitoMessenger
  # Minimal HTTP transport over Net::HTTP. Anything answering #call with the same signature can replace it:
  # the specs pass a fake, and the Zammad glue may pass one that honours the system's proxy settings.
  #
  # Connections are kept open and reused per host for the life of the transport (one job, one poll), because
  # Avito drops new connections from an address that opens many: on 2026-10-20 connects from our server took
  # 15 s every other time, the first SYNs dropped, while requests on an open connection went through.
  class Transport
    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    NETWORK_ERRORS = [
      SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError, Net::HTTPBadResponse
    ].freeze

    KEEP_ALIVE = 30

    def initialize(open_timeout: 20, read_timeout: 30)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @connections  = {}
    end

    # Header names in the response are lower-case. A connection that could not be opened is tried once more:
    # nothing was sent on it, so even a POST is safe to repeat.
    def call(method, url, headers: {}, body: nil)
      uri     = URI(url)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      attempts = 0
      begin
        attempts += 1
        response = connection(uri).request(request)
      rescue Net::OpenTimeout, Errno::ECONNREFUSED => e
        drop(uri)
        retry if attempts < 2
        raise Error::Network, "#{e.class}: #{e.message}"
      rescue *NETWORK_ERRORS => e
        drop(uri)
        raise Error::Network, "#{e.class}: #{e.message}"
      end

      Response.new(status: response.code.to_i, headers: response.each_header.to_h, body: response.body.to_s)
    end

    def finish
      @connections.each_value { |http| http.finish if http.started? }
      @connections.clear
    end

    private

    def connection(uri)
      key  = [uri.scheme, uri.host, uri.port]
      http = @connections[key]
      return http if http&.started?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl            = uri.scheme == 'https'
      http.open_timeout       = @open_timeout
      http.read_timeout       = @read_timeout
      http.keep_alive_timeout = KEEP_ALIVE
      http.start
      @connections[key] = http
    end

    def drop(uri)
      http = @connections.delete([uri.scheme, uri.host, uri.port])
      http.finish if http&.started?
    rescue IOError
      nil
    end
  end
end
