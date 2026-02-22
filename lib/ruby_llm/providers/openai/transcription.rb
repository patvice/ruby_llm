# frozen_string_literal: true

module RubyLLM
  module Providers
    class OpenAI
      # Audio transcription methods for the OpenAI API integration
      module Transcription
        def transcribe(audio_file, model:, language:, **options, &block)
          return super unless block_given?

          file_part = build_audio_file_part(audio_file)
          payload = render_transcription_payload(file_part, model:, language:, _stream: true, **options)

          stream_transcription_response(payload, model:, &block)
        end

        module_function

        def transcription_url
          'audio/transcriptions'
        end

        def render_transcription_payload(file_part, model:, language:, **options)
          stream = options.delete(:_stream)

          {
            model: model,
            file: file_part,
            language: language,
            chunking_strategy: (options[:chunking_strategy] || 'auto' if supports_chunking_strategy?(model, options)),
            stream: stream,
            response_format: response_format_for(model, options),
            prompt: options[:prompt],
            temperature: options[:temperature],
            timestamp_granularities: options[:timestamp_granularities],
            known_speaker_names: options[:speaker_names],
            known_speaker_references: encode_speaker_references(options[:speaker_references])
          }.compact
        end

        def encode_speaker_references(references)
          return nil unless references

          references.map do |ref|
            Attachment.new(ref).for_llm
          end
        end

        def response_format_for(model, options)
          return options[:response_format] if options.key?(:response_format)

          'diarized_json' if model.include?('diarize')
        end

        def supports_chunking_strategy?(model, options)
          return false if model.start_with?('whisper')
          return true if options.key?(:chunking_strategy)

          model.include?('diarize')
        end

        def parse_transcription_response(response, model:)
          data = response.body

          return RubyLLM::Transcription.new(text: data, model: model) if data.is_a?(String)

          usage = data['usage'] || {}

          RubyLLM::Transcription.new(
            text: data['text'],
            model: model,
            language: data['language'],
            duration: data['duration'],
            segments: data['segments'],
            input_tokens: usage['input_tokens'] || usage['prompt_tokens'],
            output_tokens: usage['output_tokens'] || usage['completion_tokens']
          )
        end

        def stream_transcription_response(payload, model:, &block)
          text = +''
          segments = []
          state = { usage: nil }
          stream_state = {
            parser: EventStreamParser::Parser.new,
            text: text,
            segments: segments,
            state: state,
            error_buffer: +'',
            on_event: block
          }

          @connection.post transcription_url, payload do |req|
            set_transcription_stream_handler(req, stream_state)
          end

          RubyLLM::Transcription.new(
            text: text,
            model: model,
            segments: segments.empty? ? nil : segments,
            input_tokens: state[:usage]&.dig('input_tokens') || state[:usage]&.dig('prompt_tokens'),
            output_tokens: state[:usage]&.dig('output_tokens') || state[:usage]&.dig('completion_tokens')
          )
        end

        def set_transcription_stream_handler(req, stream_state)
          if faraday_1?
            req.options[:on_data] = transcription_faraday_1_handler(stream_state)
          else
            req.options.on_data = transcription_faraday_2_handler(stream_state)
          end
        end

        def transcription_faraday_1_handler(stream_state)
          proc do |chunk, _size|
            handle_transcription_sse_chunk(chunk, stream_state[:parser], nil) do |event|
              stream_state[:state][:usage] = accumulate_transcription_event(
                event,
                stream_state[:text],
                stream_state[:segments],
                stream_state[:state][:usage]
              )
              stream_state[:on_event].call(event)
            end
          end
        end

        def transcription_faraday_2_handler(stream_state)
          proc do |chunk, _bytes, env|
            if env&.status == 200
              handle_transcription_sse_chunk(chunk, stream_state[:parser], env) do |event|
                stream_state[:state][:usage] = accumulate_transcription_event(
                  event,
                  stream_state[:text],
                  stream_state[:segments],
                  stream_state[:state][:usage]
                )
                stream_state[:on_event].call(event)
              end
            else
              handle_transcription_failed_response(chunk, stream_state[:error_buffer], env)
            end
          end
        end

        def handle_transcription_sse_chunk(chunk, parser, env)
          parser.feed(chunk) do |type, data|
            if type.to_sym == :error
              handle_transcription_error_event(data, env)
            elsif data != '[DONE]'
              event = parse_transcription_stream_event(data)
              yield event if event
            end
          end
        end

        def accumulate_transcription_event(event, text, segments, current_usage)
          text << event.delta if event.delta?
          segments << event.segment if event.segment?
          text.replace(event.text) if event.done? && event.text

          event.usage || current_usage
        end

        def parse_transcription_stream_event(data)
          event = JSON.parse(data)
          return unless event.is_a?(Hash)

          segment = if event['type'] == 'transcript.text.segment'
                      event_hash = event.dup
                      event_hash.delete('type')
                      event_hash.delete('usage')
                      event_hash
                    end

          RubyLLM::TranscriptionChunk.new(
            type: event['type'],
            delta: event['delta'],
            text: event['text'],
            segment: segment,
            usage: event['usage'],
            raw: event
          )
        rescue JSON::ParserError => e
          RubyLLM.logger.debug "Failed to parse transcription stream event: #{e.message}"
          nil
        end

        def handle_transcription_error_event(data, env)
          status, _message = parse_streaming_error(data)
          parsed_data = JSON.parse(data)

          error_response = if faraday_1?
                             Struct.new(:body, :status).new(parsed_data, status)
                           else
                             env.merge(body: parsed_data, status: status)
                           end

          ErrorMiddleware.parse_error(provider: self, response: error_response)
        rescue JSON::ParserError => e
          RubyLLM.logger.debug "Failed to parse transcription error event: #{e.message}"
        end

        def handle_transcription_failed_response(chunk, buffer, env)
          buffer << chunk
          error_data = JSON.parse(buffer)
          error_response = env.merge(body: error_data)
          ErrorMiddleware.parse_error(provider: self, response: error_response)
        rescue JSON::ParserError
          RubyLLM.logger.debug "Accumulating transcription error chunk: #{chunk}"
        end
      end
    end
  end
end
