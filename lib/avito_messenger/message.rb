module AvitoMessenger
  # One chat message, as the webhook, the message list or a send call reports it. The three shapes share
  # field names; what differs is filled from the arguments (the list does not repeat chat and account ids).
  class Message
    # Texts for message types that carry no text of their own. The Zammad glue passes translated ones.
    LABELS = {
      missed_call: 'Missed call',
      deleted:     'The message was deleted',
      unsupported: 'Avito "%s" message: its content is not available through the API',
    }.freeze

    attr_reader :id, :chat_id, :account_user_id, :author_id, :type, :content, :created_at, :direction,
                :chat_type, :item_id, :read_at, :quote

    def self.from_hash(data, account_user_id: nil, chat_id: nil)
      raise Error::BadPayload, 'message is not an object' if !data.is_a?(Hash)

      id = data['id'].to_s
      raise Error::BadPayload, 'message has no id' if id.empty?

      quote = data['quote']
      new(
        id:,
        chat_id:         (data['chat_id'] || chat_id)&.to_s,
        # In a webhook user_id is the account the hook is registered for; list items do not carry it.
        account_user_id: integer(data['user_id'] || account_user_id),
        author_id:       integer(data['author_id']),
        type:            data['type'].to_s,
        content:         data['content'].is_a?(Hash) ? data['content'] : {},
        created_at:      time(data['created']),
        direction:       data['direction']&.to_s,
        chat_type:       data['chat_type']&.to_s,
        item_id:         integer(data['item_id']),
        read_at:         time(data['read']),
        quote:           quote.is_a?(Hash) && quote['id'] ? from_hash(quote, account_user_id:, chat_id:) : nil,
      )
    end

    def self.integer(value)
      return nil if value.nil? || value.to_s.empty?

      Integer(value.to_s, 10)
    rescue ArgumentError
      nil
    end

    def self.time(value)
      seconds = integer(value)
      seconds && seconds.positive? ? Time.at(seconds).utc : nil
    end

    def initialize(id:, chat_id:, account_user_id:, author_id:, type:, content:, created_at:, direction:, chat_type:,
                   item_id:, read_at:, quote:)
      @id              = id
      @chat_id         = chat_id
      @account_user_id = account_user_id
      @author_id       = author_id
      @type            = type
      @content         = content
      @created_at      = created_at
      @direction       = direction
      @chat_type       = chat_type
      @item_id         = item_id
      @read_at         = read_at
      @quote           = quote
    end

    # Who wrote it, from the account's point of view:
    #   :customer - the other side of the chat;
    #   :own      - the account itself: Zammad, or a manager in Avito's own interface;
    #   :system   - Avito's notices and bots.
    # Prefer author_id: the webhook has no direction. A send answer has no author_id, but is always ours.
    def origin
      return :system if type == 'system'
      return(author_id == account_user_id ? :own : :customer) if author_id && account_user_id

      direction == 'out' ? :own : :customer
    end

    def own?
      origin == :own
    end

    def text
      content['text'].to_s
    end

    # The largest of the sizes Avito offers ("1280x960" => url).
    def image_url
      sizes = content.dig('image', 'sizes')
      return nil if !sizes.is_a?(Hash) || sizes.empty?

      sizes.max_by { |dimensions, _url| dimensions.to_s.split('x').map(&:to_i).inject(1, :*) }.last
    end

    def voice_id
      content.dig('voice', 'voice_id')
    end

    # Plain text for the article body. Images and voice travel as attachments, so their body is empty.
    def render_text(labels = LABELS)
      case type
      when 'text', 'system' then text
      when 'image', 'voice' then ''
      when 'item'           then join_lines(content['item'], %w[title price_string item_url])
      when 'link'           then render_link
      when 'location'       then render_location
      when 'call'           then labels[:missed_call]
      when 'deleted'        then labels[:deleted]
      else format(labels[:unsupported], type)
      end
    end

    private

    def render_link
      link = content['link'].is_a?(Hash) ? content['link'] : {}
      text = link['text'].to_s
      url  = link['url'].to_s
      return text if url.empty? || text.include?(url)
      return url if text.empty?

      "#{text}\n#{url}"
    end

    def render_location
      location = content['location'].is_a?(Hash) ? content['location'] : {}
      point = "#{location['lat']}, #{location['lon']}" if location['lat'] && location['lon']
      [location['title'], location['text'], point].map(&:to_s).reject(&:empty?).uniq.join("\n")
    end

    def join_lines(hash, keys)
      return '' if !hash.is_a?(Hash)

      keys.map { |key| hash[key].to_s }.reject(&:empty?).join("\n")
    end
  end
end
