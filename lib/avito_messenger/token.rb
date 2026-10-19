module AvitoMessenger
  # An access token and the moment it stops working. The caller keeps it between client instances
  # (the Zammad glue stores it in the channel), so a token is fetched once a day, not once per request.
  class Token
    # Refresh this long before expiry, so a request never starts with a token about to lapse.
    REFRESH_MARGIN = 300

    attr_reader :access_token, :expires_at

    def self.from_h(hash)
      return nil if !hash.is_a?(Hash)

      access_token = hash['access_token'] || hash[:access_token]
      expires_at   = hash['expires_at'] || hash[:expires_at]
      return nil if access_token.to_s.empty? || expires_at.nil?

      new(access_token:, expires_at: Time.at(Integer(expires_at)).utc)
    end

    def initialize(access_token:, expires_at:)
      @access_token = access_token
      @expires_at   = expires_at
    end

    def usable?(now)
      !access_token.to_s.empty? && !expires_at.nil? && now < expires_at - REFRESH_MARGIN
    end

    def to_h
      { 'access_token' => access_token, 'expires_at' => expires_at.to_i }
    end
  end
end
