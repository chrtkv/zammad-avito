module AvitoChannel
  # Sends an agent's reply to the Avito chat of its ticket.
  #
  # A reply becomes pieces: its text cut to Avito's 1000-character messages, then one piece per image. Each
  # piece is marked as attempted before it is sent and gets its Avito message id right after, both saved on
  # the article. A retry therefore skips what went out already, and a piece that was attempted but has no id
  # (the answer was lost) is first looked for among the chat's latest messages instead of being sent twice.
  class Delivery
    class Undeliverable < StandardError; end

    RECOVERY_WINDOW = 20

    attr_reader :article

    def initialize(article, client: nil, transport: AvitoMessenger::Transport.new)
      @article = article
      @ticket  = article.ticket
      @channel = Channel.find_by(id: @ticket.preferences[:channel_id], area: AREA)
      raise Undeliverable, "ticket #{@ticket.id} has no Avito channel" if !@channel
      # A disabled account is off both ways: nothing comes in and nothing goes out.
      if !@channel.active
        raise Undeliverable, AvitoChannel.translate(__('The Avito account is disabled; replies are not sent.'))
      end

      @user_id = @channel.options[:user_id]
      @chat_id = @ticket.preferences.dig(:avito, :chat_id)
      raise Undeliverable, "ticket #{@ticket.id} has no Avito chat" if @chat_id.blank?

      @transport = transport
      @client    = client || AvitoChannel.client(@channel, transport:)
    end

    def deliver!
      check_attachments!

      article.preferences['avito'] ||= {}
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

      if piece['attempted_at'] && (found = sent_already(piece))
        confirm(index, found)
        return
      end

      update_piece(index, 'attempted_at' => Time.zone.now.to_i)
      confirm(index, send_piece(pieces[index]))
    end

    def send_piece(piece)
      send_piece!(piece)
    rescue AvitoMessenger::Error::SubscriptionRequired => e
      # The subscription does not cover this chat's listing: retrying cannot help.
      raise Undeliverable, e.message
    end

    def send_piece!(piece)
      if piece['kind'] == 'text'
        @client.send_text(@user_id, @chat_id, piece['text']).id
      else
        file     = Store.find(piece['store_id'])
        image_id = @client.upload_image(@user_id, filename: file.filename, content: file.content,
                                                  content_type: content_type(file))
        @client.send_image(@user_id, @chat_id, image_id).id
      end
    end

    def confirm(index, avito_message_id)
      update_piece(index, 'message_id' => avito_message_id)
      AvitoMessageRef.claim!(@channel, @chat_id, avito_message_id, article)
    end

    # A piece attempted before without an id may have gone out with its answer lost. Look for it among the
    # chat's latest messages, written at or after the attempt: a text by its text, an image as any own image
    # Zammad does not know yet (Avito returns no checksum to compare; a manager sending a picture in Avito in
    # the same minutes is the one case that would be mistaken for ours).
    def sent_already(piece)
      candidate = [{ article_id: article.id, chat_id: @chat_id, kind: piece['kind'], text: piece['text'],
                     sent_at: Time.zone.at(piece['attempted_at']) }]
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
