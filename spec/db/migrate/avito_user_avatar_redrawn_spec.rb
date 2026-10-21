require 'rails_helper'

RSpec.describe AvitoUserAvatarRedrawn, type: :db_migration do
  it 'replaces the "Avito" user\'s avatar with the current picture' do
    user = AvitoChannel::ServiceUser.avito
    Avatar.add(object: 'User', o_id: user.id, full: { content: 'old', mime_type: 'image/png' },
               resize: { content: 'old', mime_type: 'image/png' }, source: 'avito', deletable: true,
               updated_by_id: 1, created_by_id: 1).then { |avatar| user.update!(image: avatar.store_hash) }

    migrate

    expect(user.reload.image).to eq(Digest::MD5.hexdigest(File.binread(AvitoChannel::ServiceUser::AVITO_AVATAR)))
  end
end
