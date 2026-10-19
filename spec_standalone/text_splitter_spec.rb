RSpec.describe AvitoMessenger::TextSplitter do
  def split(text, limit: 100)
    described_class.split(text, limit:)
  end

  it 'keeps a short text whole, trimmed and with plain line ends' do
    expect(split("  Привет\r\nмир  ")).to eq(["Привет\nмир"])
  end

  it 'returns nothing for blank text' do
    expect(split(" \n ")).to eq([])
  end

  it 'cuts at a paragraph break first' do
    first  = 'Первый абзац. ' * 4
    second = 'Второй абзац. ' * 4
    expect(split("#{first.strip}\n\n#{second.strip}")).to eq([first.strip, second.strip])
  end

  it 'cuts at a sentence end when there is no paragraph in reach' do
    text = ('Предложение номер один. ' * 6).strip
    chunks = split(text)
    expect(chunks).to all(end_with('.'))
    expect(chunks.join(' ')).to eq(text)
  end

  it 'cuts at a space inside one long sentence' do
    text   = ('слово ' * 40).strip
    chunks = split(text)
    expect(chunks.join(' ')).to eq(text)
    expect(chunks).to all(satisfy { |chunk| chunk.length <= 100 && !chunk.end_with?(' ') })
  end

  it 'cuts hard when nothing breaks the text' do
    expect(split('я' * 250)).to eq(['я' * 100, 'я' * 100, 'я' * 50])
  end

  it 'does not leave a stub when the only break is near the start' do
    text = "Ок\n#{'я' * 150}"
    expect(split(text).first.length).to eq(100)
  end

  it 'never exceeds the real Avito limit' do
    text = Array.new(30) { |i| "Абзац #{i}. #{'текст ' * 20}" }.join("\n\n")
    chunks = described_class.split(text)
    expect(chunks.size).to be > 1
    expect(chunks.map(&:length).max).to be <= 1000
  end
end
