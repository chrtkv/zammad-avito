require 'json'
require 'securerandom'
require 'uri'

module AvitoMessenger
  # Avito Messenger API for one account's client credentials (client_credentials grant).
  #
  #   client = AvitoMessenger::Client.new(client_id:, client_secret:, token: stored, on_token: ->(t) { store(t) })
  #   user_id = client.account['id']
  #   client.messages(user_id, chat_id)
  class Client
    BASE_URL   = 'https://api.avito.ru'.freeze
    USER_AGENT = 'zammad-avito'.freeze

    # Documented limits: text per message, page size and the largest offset for chat and message lists.
    TEXT_LIMIT  = 1000
    PAGE_LIMIT  = 100
    MAX_OFFSET  = 1000
    TOKEN_TTL   = 86_400
    RETRY_AFTER = 60

    attr_reader :token

    # on_token is called with every new Token, so the caller can persist it.
    def initialize(client_id:, client_secret:, token: nil, transport: Transport.new, clock: -> { Time.now.utc },
                   on_token: nil, base_url: BASE_URL)
      @client_id     = client_id
      @client_secret = client_secret
      @token         = token
      @transport     = transport
      @clock         = clock
      @on_token      = on_token
      @base_url      = base_url
    end

    def refresh_token!
      response = request(:post, '/token', form: {
                           grant_type: 'client_credentials', client_id: @client_id, client_secret: @client_secret,
                         })
      data = parse(response, strict: false)

      # /token answers HTTP 200 with {"error": ...} when the credentials are wrong: judge by the body.
      access_token = data['access_token'] if data.is_a?(Hash)
      if access_token.to_s.empty?
        raise Error::Auth, "Avito refused the client credentials: #{error_message(data) || "HTTP #{response.status}"}"
      end

      expires_in = Message.integer(data['expires_in']) || TOKEN_TTL
      @token = Token.new(access_token:, expires_at: @clock.call + expires_in)
      @on_token&.call(@token)
      @token
    end

    def account
      get('/core/v1/accounts/self')
    end

    # Chat hashes as documented: id, created, updated, context, users, last_message.
    def chats(user_id, offset: 0, limit: PAGE_LIMIT, chat_types: %w[u2i u2u], unread_only: false)
      query = { limit:, offset: }
      query[:unread_only] = true if unread_only
      data = get("/messenger/v2/accounts/#{user_id}/chats", query:, lists: { chat_types: })
      list = data['chats'] if data.is_a?(Hash)
      list.is_a?(Array) ? list : []
    end

    def chat(user_id, chat_id)
      get("/messenger/v2/accounts/#{user_id}/chats/#{segment(chat_id)}")
    end

    # Newest first. The trailing slash is part of the documented path.
    def messages(user_id, chat_id, offset: 0, limit: PAGE_LIMIT)
      data = get("/messenger/v3/accounts/#{user_id}/chats/#{segment(chat_id)}/messages/", query: { limit:, offset: })
      list = data.is_a?(Hash) ? data['messages'] : data
      Array(list).map { |item| Message.from_hash(item, account_user_id: user_id, chat_id:) }
    end

    # One message of at most TEXT_LIMIT characters; split longer replies with TextSplitter first.
    def send_text(user_id, chat_id, text)
      raise ArgumentError, "text is #{text.length} characters, Avito takes #{TEXT_LIMIT}" if text.length > TEXT_LIMIT

      data = post("/messenger/v1/accounts/#{user_id}/chats/#{segment(chat_id)}/messages",
                  json: { message: { text: }, type: 'text' })
      Message.from_hash(data, account_user_id: user_id, chat_id:)
    end

    # Returns the image id to pass to send_image.
    def upload_image(user_id, filename:, content:, content_type:)
      data = post("/messenger/v1/accounts/#{user_id}/uploadImages",
                  multipart: { name: 'uploadfile[]', filename:, content:, content_type: })
      image_id = data.keys.first if data.is_a?(Hash)
      raise Error::BadPayload, 'uploadImages answered without an image id' if image_id.to_s.empty?

      image_id
    end

    def send_image(user_id, chat_id, image_id)
      data = post("/messenger/v1/accounts/#{user_id}/chats/#{segment(chat_id)}/messages/image",
                  json: { image_id: })
      Message.from_hash(data, account_user_id: user_id, chat_id:)
    end

    def mark_read(user_id, chat_id)
      post("/messenger/v1/accounts/#{user_id}/chats/#{segment(chat_id)}/read")
    end

    # { voice_id => url }
    def voice_urls(user_id, voice_ids)
      data = get("/messenger/v1/accounts/#{user_id}/getVoiceFiles", lists: { voice_ids: })
      urls = data['voices_urls'] if data.is_a?(Hash)
      urls.is_a?(Hash) ? urls : {}
    end

    # [{ 'url' => ..., 'version' => ... }]. A POST that changes nothing.
    def subscriptions
      data = post('/messenger/v1/subscriptions', json: {})
      list = data['subscriptions'] if data.is_a?(Hash)
      list.is_a?(Array) ? list : []
    end

    def subscribe_webhook(url)
      post('/messenger/v3/webhook', json: { url: })
    end

    def unsubscribe_webhook(url)
      post('/messenger/v1/webhook/unsubscribe', json: { url: })
    end

    private

    def get(path, **)
      authorized(:get, path, **)
    end

    def post(path, **)
      authorized(:post, path, **)
    end

    def authorized(method, path, **)
      refresh_token! if !@token&.usable?(@clock.call)
      response = request(method, path, bearer: @token.access_token, **)

      # Once: a cached token can be revoked before its expiry. A second refusal is reported as is.
      if token_refused?(response)
        refresh_token!
        response = request(method, path, bearer: @token.access_token, **)
      end

      check!(response)
      parse(response)
    end

    # Avito refuses a bad token with 401, or with 403 and {"result": {"message": "invalid access token"}}
    # (seen on the live API on 2026-10-20). Any other 403 is a real refusal and is not retried.
    def token_refused?(response)
      return true if response.status == 401
      return false if response.status != 403

      response.body.to_s.match?(/token/i)
    end

    def request(method, path, bearer: nil, query: {}, lists: {}, json: nil, form: nil, multipart: nil)
      headers = { 'Accept' => 'application/json', 'User-Agent' => USER_AGENT }
      headers['Authorization'] = "Bearer #{bearer}" if bearer

      body = nil
      if json
        headers['Content-Type'] = 'application/json'
        body = JSON.generate(json)
      elsif form
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
        body = URI.encode_www_form(form)
      elsif multipart
        body, headers['Content-Type'] = multipart_body(multipart)
      end

      @transport.call(method, url(path, query, lists), headers:, body:)
    end

    # Array parameters go comma-separated: chat_types=u2i,u2u. Avito takes only one value of repeated keys
    # (checked on the live API on 2026-10-20: repeated keys returned u2i chats alone).
    def url(path, query, lists)
      pairs = query.map { |key, value| [key.to_s, value.to_s] }
      lists.each { |key, values| pairs << [key.to_s, Array(values).join(',')] if Array(values).any? }
      pairs.empty? ? "#{@base_url}#{path}" : "#{@base_url}#{path}?#{URI.encode_www_form(pairs)}"
    end

    def segment(value)
      URI.encode_www_form_component(value.to_s).gsub('+', '%20')
    end

    def multipart_body(part)
      boundary = "zammad-avito-#{SecureRandom.hex(12)}"
      filename = part[:filename].to_s.delete("\"\r\n")
      body = String.new(encoding: Encoding::BINARY)
      body << "--#{boundary}\r\n".b
      body << %(Content-Disposition: form-data; name="#{part[:name]}"; filename="#{filename}"\r\n).b
      body << "Content-Type: #{part[:content_type]}\r\n\r\n".b
      body << part[:content].to_s.b
      body << "\r\n--#{boundary}--\r\n".b
      [body, "multipart/form-data; boundary=#{boundary}"]
    end

    def check!(response)
      return if (200..299).cover?(response.status)

      data   = parse(response, strict: false)
      detail = error_message(data) || response.body.to_s[0, 200]

      case response.status
      when 402
        raise Error::SubscriptionRequired.new("Avito Messenger API needs a subscription: #{detail}",
                                              status: 402, body: data)
      when 429
        raise Error::RateLimited.new("Avito rate limit: #{detail}", status: 429, body: data,
                                                                    retry_after: retry_after(response))
      else
        raise Error::Api.new("Avito API answered HTTP #{response.status}: #{detail}", status: response.status, body: data)
      end
    end

    def retry_after(response)
      seconds = Message.integer((response.headers || {})['retry-after'])
      seconds&.positive? ? seconds : RETRY_AFTER
    end

    def parse(response, strict: true)
      body = response.body.to_s
      return {} if body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      raise Error::BadPayload, "Avito answered HTTP #{response.status} with a body that is not JSON" if strict

      nil
    end

    # Avito spells errors several ways: {"error": {"code", "message"}}, {"error": "...", "error_description"},
    # {"result": {"status": false, "message": "..."}}, {"message": "..."}.
    def error_message(data)
      return nil if !data.is_a?(Hash)

      error = data['error']
      message =
        case error
        when Hash   then error['message'] || error['code']
        when String then [error, data['error_description']].compact.join(': ')
        else data.dig('result', 'message') || data['message']
        end
      message.to_s.empty? ? nil : message.to_s
    end
  end
end
