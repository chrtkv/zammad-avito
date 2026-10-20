module AvitoChannel
  # Turns Avito messages into articles of the chat's ticket. Idempotent: the webhook and the poll may both
  # deliver a message, and AvitoMessageRef lets exactly one of them import it.
  #
  #   AvitoChannel::Importer.new(channel).import(message) # => article, or nil when already known
  class Importer
    CLOSED_STATES = %w[closed merged removed].freeze
    TITLE_LENGTH  = 60
    ECHO_LOOKBACK = 30.minutes

    SENDERS = { customer: 'Customer', own: 'Agent', system: 'System' }.freeze

    UNCOVERED_TAG = 'avito-api-unavailable'.freeze

    attr_reader :channel

    def initialize(channel, client: nil, transport: AvitoMessenger::Transport.new)
      @channel   = channel
      @transport = transport
      @client    = client || AvitoChannel.client(channel, transport:)
      @chats     = {}
    end

    # Chat hashes the caller already has (the poll lists them), saving a request per message.
    def remember_chat(chat)
      @chats[chat['id'].to_s] = chat
    end

    def import(message)
      return nil if AvitoMessageRef.known?(channel, message.id)

      if message.own? && (echo = echoed_article(message))
        return nil if !AvitoMessageRef.claim!(channel, message.chat_id, message.id, echo)

        record_echo(echo, message)
        return echo
      end

      return nil if !AvitoMessageRef.claim!(channel, message.chat_id, message.id)

      begin
        article = create(message)
      rescue
        AvitoMessageRef.release!(channel, message.id)
        raise
      end
      AvitoMessageRef.attach!(channel, message.id, article)
      article
    end

    # A chat whose messages Avito refuses (402: the subscription does not cover it, usually because of the
    # listing's category). The chat list still carries its latest message: that one is imported as usual, and
    # the ticket is tagged and told once, in an internal note, to read the rest and answer in Avito.
    def import_uncovered(chat)
      remember_chat(chat)
      last = chat['last_message']
      return nil if !last.is_a?(Hash) || last['id'].blank?

      message = AvitoMessenger::Message.from_hash(last, account_user_id: user_id, chat_id: chat['id'].to_s)
      article = import(message)
      ticket  = article&.ticket || chat_ticket(chat['id'])
      flag_uncovered(ticket, chat) if ticket
      article
    end

    # The chat answers again (the subscription now covers it): the tag goes.
    def clear_uncovered(chat_id)
      ticket = chat_ticket(chat_id)
      return if !ticket || !ticket.preferences.dig(:avito, :uncovered)

      ticket.tag_remove(UNCOVERED_TAG, 1)
      ticket.preferences[:avito][:uncovered] = false
      ticket.save!
    end

    private

    def user_id
      channel.options[:user_id]
    end

    # The webhook job and the poll can import two messages of one new chat at the same moment; without this
    # each would find no ticket and open one. Held until the transaction ends.
    def lock_chat(chat_id)
      key = Zlib.crc32("avito-chat:#{channel.id}:#{chat_id}")
      ActiveRecord::Base.connection.select_value("SELECT pg_advisory_xact_lock(#{key.to_i})")
    end

    def chat_ticket(chat_id)
      ref = AvitoMessageRef.where(channel_id: channel.id, chat_id: chat_id.to_s).where.not(ticket_article_id: nil).order(:id).last
      ref && Ticket::Article.find_by(id: ref.ticket_article_id)&.ticket
    end

    def flag_uncovered(ticket, chat)
      return if ticket.preferences.dig(:avito, :uncovered)

      Transaction.execute(reset_user_id: true, context: 'avito') do
        UserInfo.current_user_id = 1
        ticket.tag_add(UNCOVERED_TAG, 1)
        ticket.preferences[:avito] ||= {}
        ticket.preferences[:avito][:uncovered] = true
        ticket.save!

        Ticket::Article.create!(
          ticket_id:     ticket.id,
          type_id:       Ticket::Article::Type.lookup(name: 'note').id,
          sender_id:     Ticket::Article::Sender.lookup(name: 'System').id,
          internal:      true,
          content_type:  'text/plain',
          body:          AvitoChannel.uncovered_note(chat_item(chat)['url']),
          preferences:   { 'avito' => { 'origin' => 'avito', 'notice' => 'uncovered' } },
          created_by_id: 1,
          updated_by_id: 1,
        )
      end
    end

    def chat_item(chat)
      context = chat['context']
      return {} if !context.is_a?(Hash) || context['type'] != 'item' || !context['value'].is_a?(Hash)

      context['value']
    end

    def account_name
      channel.options[:name].presence || "Avito #{user_id}"
    end

    def create(message)
      article = nil
      Transaction.execute(reset_user_id: true, context: 'avito') do
        lock_chat(message.chat_id)
        UserInfo.current_user_id = 1
        customer = customer_for(message)
        ticket   = ticket_for(message, customer)
        article  = create_article(message, ticket, customer)
        add_attachments(article, message)
      end
      article
    end

    # -- customer -------------------------------------------------------------------------------------------

    def customer_for(message)
      buyer_id = message.origin == :customer ? message.author_id : buyer_id_from_chat(message)
      raise AvitoMessenger::Error::BadPayload, "no buyer in chat #{message.chat_id}" if buyer_id.nil?

      auth = Authorization.find_by(provider: AUTH_PROVIDER, uid: buyer_id.to_s)
      user = auth && User.find_by(id: auth.user_id)
      return user if user

      auth&.destroy
      create_customer(message, buyer_id)
    end

    def create_customer(message, buyer_id)
      profile = chat_user(message, buyer_id) || {}
      login   = "avito.#{buyer_id}"
      user    = User.find_by(login: login)
      if !user
        user = User.create!(
          login:         login,
          firstname:     profile['name'].presence || "Avito #{buyer_id}",
          lastname:      '',
          note:          profile.dig('public_user_profile', 'url').to_s,
          active:        true,
          role_ids:      Role.signup_role_ids,
          updated_by_id: 1,
          created_by_id: 1,
        )
        AvitoChannel.add_avatar(user, profile)
      end
      Authorization.create!(provider: AUTH_PROVIDER, uid: buyer_id.to_s, username: login, user_id: user.id)
      user
    end

    def buyer_id_from_chat(message)
      buyer = Array(chat(message)['users']).find { |u| u['id'].to_s != user_id.to_s }
      buyer && buyer['id']
    end

    def chat_user(message, buyer_id)
      Array(chat(message)['users']).find { |u| u['id'].to_s == buyer_id.to_s }
    end

    def chat(message)
      @chats[message.chat_id] ||= @client.chat(user_id, message.chat_id)
    end

    # -- ticket ---------------------------------------------------------------------------------------------

    # A customer message reopens the chat's ticket or starts a new one once it is closed. A message from our
    # side or from Avito goes to the chat's latest ticket as it is: it neither reopens nor starts one, unless
    # the chat has no ticket at all (a manager wrote first, in Avito).
    def ticket_for(message, customer)
      tickets = chat_tickets(message, customer)
      open    = tickets.find { |ticket| CLOSED_STATES.exclude?(ticket.state.name) }

      if message.origin == :customer
        return follow_up(open) if open

        return create_ticket(message, customer)
      end

      open || tickets.first || create_ticket(message, customer)
    end

    def chat_tickets(message, customer)
      Ticket.where(customer_id: customer.id).reorder(updated_at: :desc).select do |ticket|
        ticket.preferences[:channel_id] == channel.id && ticket.preferences.dig(:avito, :chat_id).to_s == message.chat_id
      end
    end

    def follow_up(ticket)
      if ticket.state_id != Ticket::State.find_by(default_create: true).id
        ticket.state = Ticket::State.find_by(default_follow_up: true)
        ticket.save!
      end
      ticket
    end

    def create_ticket(message, customer)
      item = chat_item(chat(message))

      Ticket.create!(
        group_id:    channel.group_id,
        title:       ticket_title(message, item),
        state_id:    Ticket::State.find_by(default_create: true).id,
        priority_id: Ticket::Priority.find_by(default_create: true).id,
        customer_id: customer.id,
        preferences: {
          channel_id: channel.id,
          avito:      {
            user_id:    user_id,
            chat_id:    message.chat_id,
            # The webhook names the chat type; the message list does not, but chat ids carry it: u2i-…, u2u-….
            chat_type:  message.chat_type || message.chat_id.to_s[/\A(u2i|u2u|a2u)-/, 1],
            item_id:    item['id'],
            item_title: item['title'],
            item_url:   item['url'],
            item_price: item['price_string'],
          }.compact,
        },
      )
    end


    def ticket_title(message, item)
      title = item['title'].presence || message.render_text(AvitoChannel.labels).presence || '-'
      title = title.squish
      title.length > TITLE_LENGTH ? "#{title[0, TITLE_LENGTH]}..." : title
    end

    # -- article --------------------------------------------------------------------------------------------

    def create_article(message, ticket, customer)
      from_customer = message.origin == :customer
      creator_id    = article_author_id(message, customer)
      UserInfo.current_user_id = creator_id

      article = Ticket::Article.create!(
        ticket_id:     ticket.id,
        type_id:       AvitoChannel.article_type.id,
        sender_id:     Ticket::Article::Sender.lookup(name: SENDERS.fetch(message.origin)).id,
        from:          from_customer ? customer.fullname : account_name,
        to:            from_customer ? account_name : customer.fullname,
        message_id:    AvitoChannel.message_id(user_id, message.chat_id, message.id),
        internal:      message.origin == :system || message.type == 'deleted',
        content_type:  'text/plain',
        body:          body(message),
        created_at:    message.created_at || Time.zone.now,
        preferences:   {
          'avito' => {
            'origin'     => 'avito',
            'message_id' => message.id,
            'chat_id'    => message.chat_id,
            'user_id'    => user_id,
            'author_id'  => message.author_id,
            'type'       => message.type,
          },
        },
        created_by_id: creator_id,
        updated_by_id: creator_id,
      )

      # Zammad names the sender of an agent article after its author, which for an import is the system user.
      article.update!(from: account_name) if !from_customer && article.from != account_name
      article
    end

    # Customers write their own messages; messages written in Avito itself go under the account's service
    # user; Avito's notices under Zammad's system user.
    def article_author_id(message, customer)
      case message.origin
      when :customer then customer.id
      when :own      then ServiceUser.for(channel, chat_user(message, user_id)).id
      else 1
      end
    end

    # Zammad wants a body; images and voice get a label, their content travels as an attachment.
    def body(message)
      text = message.render_text(AvitoChannel.labels).presence || AvitoChannel.labels[message.type.to_sym] || '-'
      return text if !message.quote

      quoted = message.quote.render_text(AvitoChannel.labels).lines.map { |line| "> #{line.chomp}" }.join("\n")
      quoted.empty? ? text : "#{quoted}\n\n#{text}"
    end

    # A file Avito offers but we cannot fetch leaves its link in the body instead of failing the import.
    def add_attachments(article, message)
      url = case message.type
            when 'image' then message.image_url
            when 'voice' then message.voice_id && @client.voice_urls(user_id, [message.voice_id])[message.voice_id]
            end
      return if url.blank?

      response = @transport.call(:get, url, headers: { 'User-Agent' => AvitoMessenger::Client::USER_AGENT })
      raise AvitoMessenger::Error::Network, "HTTP #{response.status}" if response.status != 200

      content_type = response.headers['content-type'].to_s.split(';').first.presence || 'application/octet-stream'
      Store.create!(
        object:      'Ticket::Article',
        o_id:        article.id,
        data:        response.body,
        filename:    "avito-#{message.type}-#{message.id}#{extension(content_type)}",
        preferences: { 'Mime-Type' => content_type },
      )
    rescue AvitoMessenger::Error => e
      Rails.logger.warn "Avito #{message.type} #{message.id} not downloaded: #{e.message}"
      article.update!(body: [article.body.presence, url].compact.join("\n"))
    end

    def extension(content_type)
      Rack::Mime::MIME_TYPES.invert[content_type] || ''
    end

    # -- echoes ---------------------------------------------------------------------------------------------

    # A reply Zammad sent whose Avito id never reached the article (see AvitoMessenger::Echo).
    def echoed_article(message)
      pieces = recent_replies(message.chat_id).flat_map do |article|
        unconfirmed_pieces(article).map do |piece|
          { article_id: article.id, chat_id: message.chat_id, text: piece['text'], sent_at: Time.zone.at(piece['attempted_at']) }
        end
      end
      article_id = AvitoMessenger::Echo.match(message, pieces)
      article_id && Ticket::Article.find_by(id: article_id)
    end

    def recent_replies(chat_id)
      Ticket::Article
        .where(type_id: AvitoChannel.article_type.id, created_at: ECHO_LOOKBACK.ago..)
        .where.not(sender_id: Ticket::Article::Sender.lookup(name: 'Customer').id)
        .select do |article|
          article.preferences.dig('avito', 'chat_id').to_s == chat_id.to_s &&
            article.preferences.dig('avito', 'user_id').to_s == user_id.to_s
        end
    end

    def unconfirmed_pieces(article)
      Array(article.preferences.dig('avito', 'pieces')).select do |piece|
        piece['kind'] == 'text' && piece['attempted_at'] && piece['message_id'].blank?
      end
    end

    def record_echo(article, message)
      piece = unconfirmed_pieces(article).find do |candidate|
        AvitoMessenger::Echo.normalize(candidate['text']) == AvitoMessenger::Echo.normalize(message.text)
      end
      return if !piece

      piece['message_id'] = message.id
      article.save!
    end
  end
end
