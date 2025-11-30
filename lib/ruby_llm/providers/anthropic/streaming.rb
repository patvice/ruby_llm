# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Streaming methods of the Anthropic API integration
      module Streaming
        private

        def stream_url
          completion_url
        end

        def build_chunk(data)
          # Reset tracking on message_start (beginning of new stream)
          reset_thinking_block_tracking if data['type'] == 'message_start'

          # Track thinking blocks through their lifecycle
          track_thinking_block(data)
          thinking_complete, complete_block = extract_complete_thinking_block(data)

          Chunk.new(
            role: :assistant,
            model_id: extract_model_id(data),
            content: data.dig('delta', 'text'),
            input_tokens: extract_input_tokens(data),
            output_tokens: extract_output_tokens(data),
            cached_tokens: extract_cached_tokens(data),
            cache_creation_tokens: extract_cache_creation_tokens(data),
            thinking: extract_thinking(data),
            thinking_block_complete: thinking_complete,
            complete_thinking_block: complete_block,
            tool_calls: extract_tool_calls(data)
          )
        end

        def reset_thinking_block_tracking
          @thinking_blocks = {}
        end

        def track_thinking_block(data)
          @thinking_blocks ||= {}

          case data['type']
          when 'content_block_start'
            content_block = data['content_block']
            return unless content_block

            block_type = content_block['type']
            return unless block_type == 'thinking' || block_type == 'redacted_thinking'

            index = data['index']
            @thinking_blocks[index] = {
              'type' => block_type,
              'thinking' => +''
            }

          when 'content_block_delta'
            delta = data['delta']
            return unless delta

            index = data['index']
            block = @thinking_blocks[index]
            return unless block

            case delta['type']
            when 'thinking_delta'
              block['thinking'] << (delta['thinking'] || '')
            when 'signature_delta'
              block['signature'] ||= +''
              block['signature'] << (delta['signature'] || '')
            end

          when 'content_block_stop'
            # Check if the stop event itself contains signature (newer API format)
            content_block = data['content_block']
            if content_block && content_block['signature']
              index = data['index']
              block = @thinking_blocks[index]
              block['signature'] = content_block['signature'] if block
            end
          end
        end

        def extract_complete_thinking_block(data)
          return [false, nil] unless data['type'] == 'content_block_stop'

          index = data['index']
          @thinking_blocks ||= {}
          block = @thinking_blocks[index]

          return [false, nil] unless block
          return [false, nil] unless block['type'] == 'thinking' || block['type'] == 'redacted_thinking'

          # Clean up tracked block and return it
          complete_block = @thinking_blocks.delete(index)
          [true, complete_block]
        end

        def json_delta?(data)
          data['type'] == 'content_block_delta' && data.dig('delta', 'type') == 'input_json_delta'
        end

        def parse_streaming_error(data)
          error_data = JSON.parse(data)
          return unless error_data['type'] == 'error'

          case error_data.dig('error', 'type')
          when 'overloaded_error'
            [529, error_data['error']['message']]
          else
            [500, error_data['error']['message']]
          end
        end
      end
    end
  end
end
