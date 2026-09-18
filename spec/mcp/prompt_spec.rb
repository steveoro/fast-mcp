# frozen_string_literal: true

RSpec.describe FastMcp::Prompt do
  let(:prompt_class) do
    Class.new(described_class) do
      prompt_name 'recall'
      description 'Recall project knowledge'
      argument :topic, description: 'Subject to recall', required: true

      def messages(topic:)
        [{ role: 'user', content: { type: 'text', text: "Recall #{topic}" } }]
      end
    end
  end

  describe '.metadata' do
    it 'returns protocol prompt metadata' do
      expect(prompt_class.metadata).to eq(
        name: 'recall',
        description: 'Recall project knowledge',
        arguments: [
          { name: 'topic', description: 'Subject to recall', required: true }
        ]
      )
    end
  end

  describe '#messages' do
    it 'renders messages from validated arguments' do
      expect(prompt_class.new.messages(topic: 'GraphMem')).to eq(
        [{ role: 'user', content: { type: 'text', text: 'Recall GraphMem' } }]
      )
    end

    it 'requires subclasses to implement rendering' do
      expect { described_class.new.messages }.to raise_error(NotImplementedError)
    end
  end
end
