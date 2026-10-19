class AvitoChannelSupport < ActiveRecord::Migration[8.0]
  def up
    if !table_exists?(:avito_message_refs)
      create_table :avito_message_refs do |t|
        t.integer  :channel_id,        null: false
        t.string   :chat_id,           null: false, limit: 255
        t.string   :avito_message_id,  null: false, limit: 255
        t.integer  :ticket_article_id, null: true
        t.datetime :created_at,        null: false, limit: 3
      end
      add_index :avito_message_refs, %i[channel_id avito_message_id], unique: true
      add_index :avito_message_refs, %i[channel_id chat_id]
    end

    # On a fresh database the seeds run after migrations; AvitoChannel creates its records on first use then.
    return if !Setting.exists?(name: 'system_init_done')

    AvitoChannel::Setup.ensure!
  end

  def down
    drop_table :avito_message_refs, if_exists: true
  end
end
