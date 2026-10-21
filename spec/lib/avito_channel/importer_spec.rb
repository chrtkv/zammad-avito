require 'rails_helper'

RSpec.describe AvitoChannel::Importer, :aggregate_failures do
  let(:channel)  { create_avito_channel }
  let(:importer) { described_class.new(channel) }
  let(:account)  { AvitoChannelSpecHelpers::AVITO_USER_ID }
  let(:buyer)    { AvitoChannelSpecHelpers::AVITO_BUYER_ID }
  let(:chat)     { avito_chat }

  before { stub_avito_chat(chat) }

  def import(value)
    importer.import(AvitoMessenger::Message.from_hash(value))
  end

  def articles_of(ticket)
    ticket.reload.articles.sort_by(&:id)
  end

  describe 'a customer message' do
    let(:article) { import(avito_message(id: 'm1', text: 'Ещё в наличии?')) }

    it 'gives the customer their Avito avatar' do
      expect(article.ticket.customer.image).to be_present.and(not_eq('none'))
      expect(a_request(:get, "https://www.avito.ru/test-avatar/#{buyer}-256.png")).to have_been_made
    end

    it 'creates the customer from the chat' do
      customer = article.ticket.customer
      expect(customer).to have_attributes(login: "avito.#{buyer}", firstname: 'Иван')
      expect(customer.note).to include("https://www.avito.ru/user/#{buyer}")
      expect(Authorization.find_by(provider: 'avito', uid: buyer.to_s).user_id).to eq(customer.id)
    end

    it 'opens a ticket named after the listing and the buyer, in the account\'s group' do
      ticket = article.ticket
      expect(ticket).to have_attributes(title: 'Горный велосипед, 29 дюймов — Иван', group_id: channel.group_id)
      expect(ticket.state.name).to eq('new')
      expect(ticket.preferences[:channel_id]).to eq(channel.id)
      expect(ticket.preferences[:avito]).to include(
        user_id: account, chat_id: 'chat-1', item_title: 'Горный велосипед, 29 дюймов', item_url: 'https://www.avito.ru/item/1',
      )
    end

    it 'adds the message as a customer article' do
      expect(article).to have_attributes(
        body:       'Ещё в наличии?',
        internal:   false,
        message_id: "avito.#{account}.chat-1.m1",
        from:       'Иван',
        to:         'Demo Shop',
      )
      expect(article.sender.name).to eq('Customer')
      expect(article.type.name).to eq('avito message')
      expect(AvitoMessageRef.known?(channel, 'm1')).to be(true)
    end

    it 'is imported once, however often it is delivered' do
      first = article
      expect(import(avito_message(id: 'm1'))).to be_nil
      expect(articles_of(first.ticket).size).to eq(1)
    end

    it 'is not sent back to Avito', performs_jobs: true do
      expect { article }.not_to have_enqueued_job(CommunicateAvitoJob)
    end
  end

  describe 'the next customer message' do
    let!(:first) { import(avito_message(id: 'm1')) }

    it 'joins the open ticket of the chat' do
      second = import(avito_message(id: 'm2', text: 'Ау?'))
      expect(second.ticket).to eq(first.ticket)
    end

    it 'starts a new ticket once the chat\'s ticket is closed' do
      first.ticket.update!(state: Ticket::State.find_by(name: 'closed'))
      second = import(avito_message(id: 'm2'))
      expect(second.ticket).not_to eq(first.ticket)
    end

    it 'reopens a ticket waiting for the customer' do
      first.ticket.update!(state: Ticket::State.find_by(name: 'pending reminder'), pending_time: 1.day.from_now)
      import(avito_message(id: 'm2'))
      expect(first.ticket.reload.state.name).to eq('open')
    end
  end

  describe 'a message a manager wrote in Avito itself' do
    let!(:first) { import(avito_message(id: 'm1')) }
    let(:own)    { avito_message(id: 'm2', author_id: account, text: 'Да, в наличии.') }

    it 'is added to the ticket as an agent reply from Avito' do
      article = import(own)
      expect(article.ticket).to eq(first.ticket)
      expect(article.sender.name).to eq('Agent')
      expect(article).to have_attributes(internal: false, from: 'Demo Shop', to: 'Иван')
      expect(article.preferences.dig('avito', 'origin')).to eq('avito')
    end

    it 'is filed under the account\'s service user, wearing the shop\'s Avito avatar' do
      author = import(own).created_by
      expect(author).to have_attributes(login: "avito.account.#{account}", firstname: 'Demo Shop', lastname: '(Avito)', active: false)
      expect(author.image).to be_present.and(not_eq('none'))
      expect(a_request(:get, "https://www.avito.ru/test-avatar/#{account}-256.png")).to have_been_made
      expect(import(avito_message(id: 'm3', author_id: account, text: 'Ещё')).created_by).to eq(author)
    end

    it 'keeps one service user per account' do
      second = create_avito_channel(user_id: 111, name: 'Second shop')
      stub_avito_chat(avito_chat(user_id: 111), user_id: 111)
      theirs = described_class.new(second).import(AvitoMessenger::Message.from_hash(avito_message(id: 'x1', user_id: 111, author_id: 111)))
      ours   = import(own)
      expect(theirs.created_by).not_to eq(ours.created_by)
      expect(theirs.created_by.firstname).to eq('Second shop')
    end

    it 'is not sent back to Avito', performs_jobs: true do
      expect { import(own) }.not_to have_enqueued_job(CommunicateAvitoJob)
    end

    it 'goes to a closed ticket without reopening it' do
      first.ticket.update!(state: Ticket::State.find_by(name: 'closed'))
      article = import(own)
      expect(article.ticket).to eq(first.ticket)
      expect(first.ticket.reload.state.name).to eq('closed')
    end

    it 'reads the chat type off the chat id when the message does not name it' do
      stub_avito_chat(avito_chat(id: 'u2i-abc'))
      message = avito_message(id: 'm7', chat_id: 'u2i-abc').except('chat_type')
      expect(import(message).ticket.preferences.dig(:avito, :chat_type)).to eq('u2i')
    end

    it 'starts a ticket when the manager wrote first' do
      other_chat = avito_chat(id: 'chat-2', buyer_id: 555, buyer_name: 'Пётр')
      stub_avito_chat(other_chat)
      article = import(avito_message(id: 'm9', chat_id: 'chat-2', author_id: account, text: 'Добрый день!'))
      expect(article.ticket.customer.firstname).to eq('Пётр')
      expect(article.sender.name).to eq('Agent')
    end
  end

  describe 'the echo of a reply Zammad sent' do
    let!(:first) { import(avito_message(id: 'm1')) }

    # The send went out but its answer was lost: the piece has no Avito id.
    let!(:reply) do
      create(:ticket_article, ticket: first.ticket, type: Ticket::Article::Type.lookup(name: 'avito message'),
                              sender_name: 'Agent', body: 'Да, в наличии.',
                              preferences: { 'avito' => { 'chat_id' => 'chat-1', 'user_id' => account,
                                                          'pieces' => [{ 'kind' => 'text', 'text' => 'Да, в наличии.',
                                                                         'attempted_at' => 1.minute.ago.to_i }] } })
    end

    it 'is linked to that reply instead of becoming a second one' do
      echoed = import(avito_message(id: 'm2', author_id: account, text: 'Да, в наличии.'))

      expect(echoed).to eq(reply)
      expect(reply.reload.preferences.dig('avito', 'pieces', 0, 'message_id')).to eq('m2')
      expect(articles_of(first.ticket).size).to eq(2)
    end

    it 'leaves a different own message alone' do
      article = import(avito_message(id: 'm3', author_id: account, text: 'Другое сообщение'))
      expect(article).not_to eq(reply)
      expect(articles_of(first.ticket).size).to eq(3)
    end

    context 'when the reply was an image' do
      before do
        stub_request(:get, %r{\Ahttps://img\.example/}).to_return(status: 200, body: 'JPEG', headers: { 'Content-Type' => 'image/jpeg' })
        reply.preferences['avito']['pieces'] = [{ 'kind' => 'image', 'filename' => 'photo.png', 'image_id' => 'u1',
                                                  'image_urls' => ['https://img.example/u1.jpg'], 'attempted_at' => 1.minute.ago.to_i }]
        reply.save!
      end

      it 'links an own image carrying the upload\'s address' do
        echoed = import(avito_message(id: 'i1', author_id: account, type: 'image',
                                      content: { 'image' => { 'sizes' => { '640x480' => 'https://img.example/u1.jpg' } } }))
        expect(echoed).to eq(reply)
      end

      # Review, 2026-10-21: any own image used to pass for the reply's.
      it 'imports a manager\'s picture as a message of its own' do
        article = import(avito_message(id: 'i2', author_id: account, type: 'image',
                                       content: { 'image' => { 'sizes' => { '640x480' => 'https://img.example/manager.jpg' } } }))
        expect(article).not_to eq(reply)
        expect(reply.reload.preferences.dig('avito', 'pieces', 0, 'message_id')).to be_nil
      end
    end
  end

  describe 'the ticket\'s title and tag' do
    def title_of(**options)
      channel.options.merge!(options)
      channel.save!
      import(avito_message(id: "t-#{options.hash.abs}")).ticket
    end

    it 'follows the account\'s template' do
      expect(title_of(ticket_title: '{account}: {listing} ({buyer})').title).to eq('Demo Shop: Горный велосипед, 29 дюймов (Иван)')
    end

    it 'drops a separator the template leaves at an end' do
      expect(title_of(ticket_title: '— {listing} | ').title).to eq('Горный велосипед, 29 дюймов')
    end

    it 'is the listing alone when asked so' do
      expect(title_of(ticket_title: '{listing}').title).to eq('Горный велосипед, 29 дюймов')
    end

    it 'carries the account\'s tag when the account tags its tickets' do
      expect(title_of(ticket_tag: 'demo-shop').tag_list).to eq(['demo-shop'])
    end

    it 'carries no tag otherwise' do
      expect(title_of.tag_list).to be_empty
    end
  end

  describe 'other message types' do
    # Review, 2026-10-22: as "avito message" articles from System, Zammad showed them as '"" -> "Иван"' and hid
    # the text.
    it 'keeps Avito\'s own notices as internal notes written by the "Avito" user' do
      article = import(avito_message(id: 's1', type: 'system', author_id: 0, text: 'Покупатель оформил доставку'))

      expect(article).to have_attributes(internal: true, body: include('Покупатель оформил доставку'), from: 'Avito')
      expect(article.type.name).to eq('note')
      expect(article.sender.name).to eq('System')
      expect(article.created_by).to have_attributes(login: 'avito.system', firstname: 'Avito', active: false)
      expect(AvitoMessageRef.known?(channel, 's1')).to be(true)
    end

    it 'opens a ticket the reply form still knows as Avito\'s when the chat starts with a notice' do
      ticket = import(avito_message(id: 's1', type: 'system', author_id: 0, text: 'Пользователь создал чат')).ticket

      expect(ticket.create_article_type.name).to eq('note')
      expect(ticket.preferences.dig(:avito, :chat_id)).to eq('chat-1')
    end

    it 'stores the largest size of an image' do
      stub_request(:get, 'https://img.avito.example/1280.jpg')
        .to_return(status: 200, body: 'JPEGDATA', headers: { 'Content-Type' => 'image/jpeg' })
      sizes = { '140x105' => 'https://img.avito.example/140.jpg', '1280x960' => 'https://img.avito.example/1280.jpg' }

      article = import(avito_message(id: 'i1', type: 'image', content: { 'image' => { 'sizes' => sizes } }))

      expect(article.attachments.size).to eq(1)
      expect(article.attachments.first).to have_attributes(content: 'JPEGDATA')
      expect(article.attachments.first.preferences['Mime-Type']).to eq('image/jpeg')
      expect(article.body).to eq('Image')
    end

    it 'leaves the link in the body when an image cannot be fetched' do
      stub_request(:get, 'https://img.avito.example/1280.jpg').to_return(status: 404)
      sizes = { '1280x960' => 'https://img.avito.example/1280.jpg' }

      article = import(avito_message(id: 'i2', type: 'image', content: { 'image' => { 'sizes' => sizes } }))

      expect(article.attachments).to be_empty
      expect(article.reload.body).to include('https://img.avito.example/1280.jpg')
    end

    it 'quotes the message a customer answers to' do
      article = import(avito_message(id: 'q2', text: 'Да, этот',
                                     quote: { 'id' => 'q1', 'author_id' => account, 'type' => 'text', 'content' => { 'text' => 'Вам этот?' } }))
      expect(article.body).to eq("> Вам этот?\n\nДа, этот")
    end
  end

  describe 'several accounts' do
    let(:second_group) { create(:group) }
    let(:second)       { create_avito_channel(user_id: 111, name: 'Second shop', group: second_group) }

    before { stub_avito_chat(avito_chat(user_id: 111), user_id: 111) }

    it 'keeps each account\'s chats in its own tickets and group, with one customer per buyer' do
      ours   = import(avito_message(id: 'm1'))
      theirs = described_class.new(second).import(AvitoMessenger::Message.from_hash(avito_message(id: 'm1', user_id: 111)))

      expect(theirs).to be_present
      expect(theirs.ticket).not_to eq(ours.ticket)
      expect(theirs.ticket.group).to eq(second_group)
      expect(theirs.ticket.customer).to eq(ours.ticket.customer)
      expect(theirs.to).to eq('Second shop')
    end
  end
end
