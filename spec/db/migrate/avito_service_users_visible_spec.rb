require 'rails_helper'

RSpec.describe AvitoServiceUsersVisible, :aggregate_failures, type: :db_migration do
  def service_user(login)
    User.create!(login: login, firstname: 'Avito', active: false, updated_by_id: 1, created_by_id: 1)
  end

  it 'makes the users of Avito\'s messages active and gives the "Avito" user its avatar' do
    avito = service_user(AvitoChannel::ServiceUser::AVITO_LOGIN)
    shop  = service_user('avito.account.12345678')
    other = service_user('someone.else')

    migrate

    expect(avito.reload).to have_attributes(active: true, image: be_present.and(not_eq('none')))
    expect(shop.reload.active).to be(true)
    expect(other.reload.active).to be(false)
  end

  it 'makes no "Avito" user where there is none' do
    expect { migrate }.not_to change { User.exists?(login: AvitoChannel::ServiceUser::AVITO_LOGIN) }.from(false)
  end
end
