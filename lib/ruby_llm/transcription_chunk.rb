# frozen_string_literal: true

module RubyLLM
  # Represents a streamed transcription event.
  class TranscriptionChunk
    attr_reader :type, :delta, :text, :segment, :usage, :raw

    def initialize(type:, raw: nil, **attributes)
      @type = type
      @delta = attributes[:delta]
      @text = attributes[:text]
      @segment = attributes[:segment]
      @usage = attributes[:usage]
      @raw = raw
    end

    def content
      delta || text || segment&.dig('text')
    end

    def delta?
      type == 'transcript.text.delta'
    end

    def segment?
      type == 'transcript.text.segment'
    end

    def done?
      type == 'transcript.text.done'
    end
  end
end
