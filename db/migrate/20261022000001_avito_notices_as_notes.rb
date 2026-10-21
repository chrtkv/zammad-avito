# Avito's own notices were imported as "avito message" articles from System, which Zammad shows as a one-line
# record with their text hidden (2026-10-22). They become internal notes under the "Avito" user, as the importer
# files them now. Also brings in the texts added since (AvitoChannel::Setup).
class AvitoNoticesAsNotes < ActiveRecord::Migration[8.0]
  def up
    return if !Setting.exists?(name: 'system_init_done')

    AvitoChannel::Setup.ensure!

    avito_type = Ticket::Article::Type.lookup(name: AvitoChannel::ARTICLE_TYPE)
    system     = Ticket::Article::Sender.lookup(name: 'System')
    note       = Ticket::Article::Type.lookup(name: 'note')
    return if !avito_type || !system || !note

    notices = Ticket::Article.where(type_id: avito_type.id, sender_id: system.id)
    return if !notices.exists?

    avito = AvitoChannel::ServiceUser.avito
    notices.find_each do |article|
      article.update_columns(type_id: note.id, internal: true, from: avito.fullname, created_by_id: avito.id, # rubocop:disable Rails/SkipsModelValidations
                             updated_by_id: avito.id, updated_at: Time.zone.now)
    end
  end
end
