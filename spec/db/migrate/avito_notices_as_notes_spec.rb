require 'rails_helper'

RSpec.describe AvitoNoticesAsNotes, :aggregate_failures, type: :db_migration do
  let(:channel) { create_avito_channel }
  let(:ticket)  { create(:ticket, group: channel.group, preferences: { channel_id: channel.id, avito: { chat_id: 'chat-1' } }) }

  def article(sender:, type: AvitoChannel::ARTICLE_TYPE)
    create(:ticket_article, ticket: ticket, type: Ticket::Article::Type.lookup(name: type), sender_name: sender,
                            internal: true, body: 'Пользователь создал чат', created_by_id: 1)
  end

  it 'turns Avito\'s notices imported before into internal notes of the "Avito" user, and leaves the rest alone' do
    notice   = article(sender: 'System')
    customer = article(sender: 'Customer')
    note     = article(sender: 'System', type: 'note')

    migrate

    expect(notice.reload.type.name).to eq('note')
    expect(notice.created_by.login).to eq('avito.system')
    expect(notice.from).to eq('Avito')
    expect(customer.reload.type.name).to eq(AvitoChannel::ARTICLE_TYPE)
    expect(note.reload.created_by_id).to eq(1)
  end
end
