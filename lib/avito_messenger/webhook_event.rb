require 'json'

module AvitoMessenger
  # A webhook v3 delivery:
  #   { id, version, timestamp, payload: { type: 'message', value: { id, chat_id, user_id, author_id, ... } } }
  class WebhookEvent
    attr_reader :id, :version, :timestamp, :payload_type, :account_user_id, :message

    # Avito checks a URL by POSTing {} and expects 200: such a probe is not an event.
    def self.probe?(data)
      data.is_a?(Hash) && data.empty?
    end

    def self.parse(input)
      data = input.is_a?(String) ? JSON.parse(input) : input
      raise Error::BadPayload, 'webhook body is not an object' if !data.is_a?(Hash)

      payload = data['payload']
      raise Error::BadPayload, 'webhook body has no payload' if !payload.is_a?(Hash)

      type  = payload['type'].to_s
      value = payload['value'].is_a?(Hash) ? payload['value'] : {}
      raise Error::BadPayload, 'message event without a message' if type == 'message' && value.empty?

      new(
        id:              data['id'].to_s,
        version:         data['version'].to_s,
        timestamp:       Message.time(data['timestamp']),
        payload_type:    type,
        account_user_id: Message.integer(value['user_id']),
        message:         type == 'message' ? Message.from_hash(value) : nil,
      )
    rescue JSON::ParserError => e
      raise Error::BadPayload, "webhook body is not JSON: #{e.message}"
    end

    def initialize(id:, version:, timestamp:, payload_type:, account_user_id:, message:)
      @id              = id
      @version         = version
      @timestamp       = timestamp
      @payload_type    = payload_type
      @account_user_id = account_user_id
      @message         = message
    end

    def message?
      !message.nil?
    end

    # The payload names the account the hook is registered for; it must be the channel's account.
    def for_account?(user_id)
      !account_user_id.nil? && account_user_id == Message.integer(user_id)
    end
  end
end
