# frozen_string_literal: true

module RubyLLM
  module Providers
    class Anthropic
      # Tools methods of the Anthropic API integration
      module Tools
        module_function

        def find_tool_uses(blocks)
          blocks.select { |c| c['type'] == 'tool_use' }
        end

        def format_tool_call(msg)
          return { role: 'assistant', content: msg.content.value } if msg.content.is_a?(RubyLLM::Content::Raw)

          content = []

          # Include thinking blocks first if present (required by Anthropic when extended thinking is enabled)
          # When extended thinking is enabled, assistant messages with tool_use MUST start with thinking blocks
          # IMPORTANT: We must preserve complete blocks including 'signature' field
          add_thinking_blocks(msg.thinking, content)

          content << Media.format_text(msg.content) unless msg.content.nil? || msg.content.empty?

          msg.tool_calls.each_value do |tool_call|
            content << format_tool_use_block(tool_call)
          end

          {
            role: 'assistant',
            content:
          }
        end

        def add_thinking_blocks(thinking, content)
          return if thinking.nil?

          case thinking
          when Array
            # Raw blocks from API - include them exactly as received (preserves signature field)
            thinking.each { |block| content << block }
          when String
            # Legacy string format (e.g., from streaming accumulation or old data)
            # Note: This won't have a signature, so it may fail with extended thinking
            content << { type: 'thinking', thinking: thinking } unless thinking.empty?
          end
        end

        def format_tool_result(msg)
          {
            role: 'user',
            content: msg.content.is_a?(RubyLLM::Content::Raw) ? msg.content.value : [format_tool_result_block(msg)]
          }
        end

        def format_tool_use_block(tool_call)
          {
            type: 'tool_use',
            id: tool_call.id,
            name: tool_call.name,
            input: tool_call.arguments
          }
        end

        def format_tool_result_block(msg)
          {
            type: 'tool_result',
            tool_use_id: msg.tool_call_id,
            content: Media.format_content(msg.content)
          }
        end

        def function_for(tool)
          input_schema = tool.params_schema ||
                         RubyLLM::Tool::SchemaDefinition.from_parameters(tool.parameters)&.json_schema

          declaration = {
            name: tool.name,
            description: tool.description,
            input_schema: input_schema || default_input_schema
          }

          return declaration if tool.provider_params.empty?

          RubyLLM::Utils.deep_merge(declaration, tool.provider_params)
        end

        def extract_tool_calls(data)
          if json_delta?(data)
            { nil => ToolCall.new(id: nil, name: nil, arguments: data.dig('delta', 'partial_json')) }
          else
            parse_tool_calls(data['content_block'])
          end
        end

        def parse_tool_calls(content_blocks)
          return nil if content_blocks.nil?

          content_blocks = [content_blocks] unless content_blocks.is_a?(Array)

          tool_calls = {}
          content_blocks.each do |block|
            next unless block && block['type'] == 'tool_use'

            tool_calls[block['id']] = ToolCall.new(
              id: block['id'],
              name: block['name'],
              arguments: block['input']
            )
          end

          tool_calls.empty? ? nil : tool_calls
        end

        def default_input_schema
          {
            'type' => 'object',
            'properties' => {},
            'required' => [],
            'additionalProperties' => false,
            'strict' => true
          }
        end
      end
    end
  end
end
