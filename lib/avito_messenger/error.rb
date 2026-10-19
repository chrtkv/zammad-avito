module AvitoMessenger
  class Error < StandardError
    # The request never got an HTTP answer: DNS, connect, TLS, timeout.
    class Network < Error; end

    # /token refused the client credentials.
    class Auth < Error; end

    # An answer whose JSON is missing or not shaped as documented.
    class BadPayload < Error; end

    # Any non-2xx answer from the API.
    class Api < Error
      attr_reader :status, :body

      def initialize(message, status:, body: nil)
        super(message)
        @status = status
        @body   = body
      end
    end

    # 402: the account's tariff has no Messenger API subscription.
    class SubscriptionRequired < Api; end

    # 429: back off for retry_after seconds.
    class RateLimited < Api
      attr_reader :retry_after

      def initialize(message, status:, retry_after:, body: nil)
        super(message, status:, body:)
        @retry_after = retry_after
      end
    end
  end
end
