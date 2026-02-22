# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RubyLLM::Transcription do
  include_context 'with configured RubyLLM'

  let(:audio_path) { File.expand_path('../fixtures/ruby.wav', __dir__) }

  describe 'basic functionality' do
    TRANSCRIPTION_MODELS.each do |config|
      provider = config[:provider]
      model = config[:model]

      it "#{provider}/#{model} can transcribe audio" do
        transcription = RubyLLM.transcribe(audio_path, model: model, provider: provider)

        expect(transcription.text).to be_a(String)
        expect(transcription.text).not_to be_empty
        expect(transcription.model).to eq(model)
      end

      it "#{provider}/#{model} can transcribe with language hint" do
        transcription = RubyLLM.transcribe(audio_path, model: model, provider: provider, language: 'en')

        expect(transcription.text).to be_a(String)
        expect(transcription.text).not_to be_empty
        expect(transcription.model).to eq(model)
      end
    end

    it 'validates model existence' do
      expect do
        RubyLLM.transcribe(audio_path, model: 'invalid-transcription-model')
      end.to raise_error(RubyLLM::ModelNotFoundError)
    end
  end

  describe 'streaming functionality' do
    it 'streams diarization events and returns a final transcription' do
      stream_body = [
        { type: 'transcript.text.delta', delta: 'Hello ' },
        { type: 'transcript.text.segment', id: 'seg_0', speaker: 'A', start: 0.0, end: 0.9, text: 'Hello world' },
        { type: 'transcript.text.delta', delta: 'world' },
        { type: 'transcript.text.done', text: 'Hello world', usage: { input_tokens: 10, output_tokens: 5 } },
        '[DONE]'
      ].map { |event| "data: #{event.is_a?(String) ? event : event.to_json}\n\n" }.join

      captured_payload = nil
      mock_connection = instance_double(RubyLLM::Connection)
      allow(RubyLLM::Connection).to receive(:new).and_return(mock_connection)
      allow(mock_connection).to receive(:post) do |_url, payload, &request_block|
        captured_payload = payload

        options = Struct.new(:on_data).new
        request = Struct.new(:options, :headers).new(options, {})
        request_block.call(request)
        env = Struct.new(:status).new(200)
        request.options.on_data.call(stream_body, stream_body.bytesize, env)

        instance_double(Faraday::Response, body: nil)
      end

      chunks = []
      transcription = RubyLLM.transcribe(
        audio_path,
        model: 'gpt-4o-transcribe-diarize',
        provider: :openai
      ) do |chunk|
        chunks << chunk
      end

      expect(chunks).not_to be_empty
      expect(chunks).to all(be_a(RubyLLM::TranscriptionChunk))

      segment_chunk = chunks.find(&:segment?)
      expect(segment_chunk).to be_present
      expect(segment_chunk.segment['speaker']).to eq('A')

      expect(transcription.text).to eq('Hello world')
      expect(transcription.segments).to eq(
        [{ 'id' => 'seg_0', 'speaker' => 'A', 'start' => 0.0, 'end' => 0.9, 'text' => 'Hello world' }]
      )
      expect(transcription.input_tokens).to eq(10)
      expect(transcription.output_tokens).to eq(5)

      expect(captured_payload[:stream]).to be(true)
    end
  end
end
