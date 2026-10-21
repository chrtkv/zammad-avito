module AvitoChannel
  # Sends an agent's reply to an Avito chat of its ticket (see #route for which one).
  #
  # A reply becomes pieces: its text cut to Avito's 1000-character messages, then one piece per image. Each
  # piece is marked as attempted before it is sent and gets its Avito message id right after, both saved on
  # the article. A retry therefore skips what went out already, and a piece that was attempted but has no id
  # (the answer was lost) is first looked for among the chat's latest messages instead of being sent twice.
  # An image that was handed to send_image and cannot be found there stops the delivery with a request to
  # look in Avito: sending it again could show the customer the picture twice, and taking another own image
  # for it could report a picture as delivered that never was.
  class Delivery
    class Undeliverable < StandardError; end

    RECOVERY_WINDOW = 20

    attr_reader :article

    def initialize(article, client: nil, transport: AvitoMessenger::Transport.new)
      @article = article
      @ticket  = article.ticket
      @channel, @chat_id = route
      raise Undeliverable, "ticket #{@ticket.id} has no Avito channel" if !@channel
      # A disabled account is off both ways: nothing comes in and nothing goes out.
      if !@channel.active
        raise Undeliverable, AvitoChannel.translate(__('The Avito account is disabled; replies are not sent.'))
      end

      @user_id = @channel.options[:user_id]
      raise Undeliverable, "ticket #{@ticket.id} has no Avito chat" if @chat_id.blank?

      @transport = transport
      @client    = client || AvitoChannel.client(@channel, transport:)
    end

    def deliver!
      check_attachments!

      article.preferences['avito'] ||= {}
      article.preferences['avito']['channel_id'] = @channel.id
      article.preferences['avito']['chat_id'] = @chat_id
      article.preferences['avito']['user_id'] = @user_id
      article.preferences['avito']['pieces'] ||= build_pieces
      article.save!

      pieces.size.times { |index| deliver_piece(index) }

      first_id = pieces.pluck('message_id').compact.first
      article.message_id = AvitoChannel.message_id(@user_id, @chat_id, first_id) if first_id
      article.from = @channel.options[:name].presence || "Avito #{@user_id}"
      article.to   = @ticket.customer&.fullname
      article.save!

      mark_read
      article
    ensure
      @transport.finish
    end

    private

    # The channel and chat the reply goes to. A ticket can hold several chats: Zammad merges tickets, a merged
    # chat's messages keep landing where it was merged (Importer#chat_tickets), and the ticket's preferences
    # name only its own first chat, so taking them would answer one buyer in another buyer's chat (review,
    # 2026-10-21). In this order:
    #   - where the reply's first attempt went: a retry finishes in the chat that has its first pieces;
    #   - the chat of the message it answers (in_reply_to, which the "reply" action sets);
    #   - the ticket's one chat. With several, nothing is sent: the agent picks one by replying to its message.
    def route
      stored = article.preferences['avito']
      if stored.is_a?(Hash) && stored['chat_id'].present?
        return [channel(stored['channel_id'] || @ticket.preferences[:channel_id]), stored['chat_id']]
      end

      refs = AvitoMessageRef.where(ticket_article_id: @ticket.articles.select(:id))
      replied_route(refs) || ticket_route(refs)
    end

    def replied_route(refs)
      replied = article.in_reply_to.presence && @ticket.articles.find_by(message_id: article.in_reply_to)
      ref     = replied && refs.find_by(ticket_article_id: replied.id)
      ref && [channel(ref.channel_id), ref.chat_id]
    end

    def ticket_route(refs)
      chats = refs.distinct.pluck(:channel_id, :chat_id)
      if chats.size > 1
        raise Undeliverable, AvitoChannel.translate(__('This ticket holds several Avito chats (tickets were merged). Use "reply" on a message of the chat this answer is for.'))
      end
      return [channel(chats[0][0]), chats[0][1]] if chats.one?

      [channel(@ticket.preferences[:channel_id]), @ticket.preferences.dig(:avito, :chat_id)]
    end

    def channel(id)
      Channel.find_by(id:, area: AREA)
    end

    def check_attachments!
      others = attachments.reject { |file| image?(file) }
      return if others.empty?

      raise Undeliverable, "Avito accepts only images; not sent: #{others.map(&:filename).join(', ')}"
    end

    def build_pieces
      texts  = AvitoMessenger::TextSplitter.split(plain_body).map { |text| { 'kind' => 'text', 'text' => text } }
      images = attachments.map { |file| { 'kind' => 'image', 'store_id' => file.id, 'filename' => file.filename } }
      pieces = texts + images
      raise Undeliverable, 'the reply is empty' if pieces.empty?

      pieces
    end

    # Saving an article hands its preferences a fresh copy, so pieces are read anew by index after every save
    # rather than held on to.
    def pieces
      article.preferences.dig('avito', 'pieces') || []
    end

    def update_piece(index, attributes)
      pieces[index].merge!(attributes)
      article.save!
    end

    def deliver_piece(index)
      piece = pieces[index]
      return if piece['message_id'].present?

      if piece['attempted_at']
        if (found = sent_already(piece))
          confirm(index, found)
          return
        end
        unconfirmed_image!(piece) if piece['kind'] == 'image' && piece['image_id'].present?
      end

      update_piece(index, 'attempted_at' => Time.zone.now.to_i)
      confirm(index, send_piece(index))
    end

    def unconfirmed_image!(piece)
      raise Undeliverable, AvitoChannel.translate(__('Avito did not confirm whether the image %s reached the chat. Look at the chat in Avito and send the image again if it is missing.'), piece['filename'])
    end

    def send_piece(index)
      send_piece!(index)
    rescue AvitoMessenger::Error::SubscriptionRequired => e
      # The subscription does not cover this chat's listing: retrying cannot help.
      raise Undeliverable, e.message
    end

    # An image's upload is saved while it is being sent, and dropped again when Avito refuses the send (4xx):
    # an image that still has an image_id may have reached the chat with its answer lost, one without has not
    # (see #unconfirmed_image!). A 5xx keeps it: a failing gateway says nothing about whether Avito took the
    # message, and a retry before it shows in the chat sent the picture twice (review, 2026-10-21).
    def send_piece!(index)
      piece = pieces[index]
      return @client.send_text(@user_id, @chat_id, piece['text']).id if piece['kind'] == 'text'

      file  = Store.find(piece['store_id'])
      image = @client.upload_image(@user_id, filename: file.filename, content: file.content, content_type: content_type(file))
      update_piece(index, 'image_id' => image.id, 'image_urls' => image.urls)
      begin
        @client.send_image(@user_id, @chat_id, image.id).id
      rescue AvitoMessenger::Error::Api => e
        update_piece(index, 'image_id' => nil) if e.status < 500
        raise
      end
    end

    def confirm(index, avito_message_id)
      update_piece(index, 'message_id' => avito_message_id)
      AvitoMessageRef.claim!(@channel, @chat_id, avito_message_id, article)
    end

    # A piece attempted before without an id may have gone out with its answer lost. Look for it among the
    # chat's latest messages, written at or after the attempt: a text by its text, an image by the addresses
    # its upload got (AvitoMessenger::Echo).
    def sent_already(piece)
      candidate = [{ article_id: article.id, chat_id: @chat_id, kind: piece['kind'], text: piece['text'],
                     image_urls: piece['image_urls'], sent_at: Time.zone.at(piece['attempted_at']) }]
      @client.messages(@user_id, @chat_id, limit: RECOVERY_WINDOW)
        .reject { |message| AvitoMessageRef.known?(@channel, message.id) }
        .find { |message| AvitoMessenger::Echo.match(message, candidate) }
        &.id
    end

    def mark_read
      return if @channel.options[:mark_read] == false

      @client.mark_read(@user_id, @chat_id)
    rescue AvitoMessenger::Error => e
      Rails.logger.info "Avito chat #{@chat_id} not marked read: #{e.message}"
    end

    def plain_body
      body = article.body.to_s
      article.content_type == 'text/html' ? body.html2text : body
    end

    def attachments
      @attachments ||= article.attachments.reject { |file| file.preferences['Content-Disposition'] == 'inline' }
    end

    def image?(file)
      content_type(file).start_with?('image/')
    end

    def content_type(file)
      (file.preferences['Content-Type'] || file.preferences['Mime-Type']).to_s
    end
  end
end
