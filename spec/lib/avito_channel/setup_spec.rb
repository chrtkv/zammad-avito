require 'rails_helper'

RSpec.describe AvitoChannel::Setup, :aggregate_failures do
  # The package's files as bin/zammad-spec copied them over Zammad's tree.
  let(:files) do
    patterns = %w[
      app/assets/javascripts/app/**/*avito*.coffee app/assets/javascripts/app/views/avito/*.eco
      app/**/*avito*.rb lib/avito_channel.rb lib/avito_channel/*.rb
    ]
    patterns.flat_map { |pattern| Rails.root.glob(pattern).map(&:to_s) }.uniq
  end

  # __('…') and @T('…') with a literal first argument, quotes unescaped.
  let(:texts) do
    files.flat_map do |file|
      File.read(file).scan(%r{(?:\b__|@T)\(\s*(['"])((?:\\.|(?!\1).)*)\1}).map { |_quote, text| text.gsub(%r{\\(['"])}, '\1') }
    end.uniq
  end

  it 'has a Russian translation for every text the package marks for translation' do
    described_class.ensure!

    expect(files).to include(end_with('lib/avito_channel/setup.rb'), end_with('views/avito/index.jst.eco'))
    missing = texts.reject { |text| Translation.where(locale: 'ru', source: text).where.not(target: '').exists? }
    expect(missing).to be_empty
  end
end
