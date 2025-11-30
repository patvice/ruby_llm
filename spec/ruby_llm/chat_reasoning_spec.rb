# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Reasoning output support' do
  include_context 'with configured RubyLLM'

  describe RubyLLM::Message do
    it 'includes thinking attribute' do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: 'Hello',
        thinking: 'Let me think about this...'
      )

      expect(message.thinking).to eq('Let me think about this...')
    end

    it 'includes thinking in to_h' do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: 'Hello',
        thinking: 'Some reasoning'
      )

      expect(message.to_h[:thinking]).to eq('Some reasoning')
    end

    it 'handles nil thinking' do
      message = RubyLLM::Message.new(
        role: :assistant,
        content: 'Hello'
      )

      expect(message.thinking).to be_nil
      expect(message.to_h).not_to have_key(:thinking)
    end
  end

  describe RubyLLM::Chunk do
    it 'inherits thinking attribute from Message' do
      chunk = RubyLLM::Chunk.new(
        role: :assistant,
        content: 'partial',
        thinking: 'thinking part'
      )

      expect(chunk.thinking).to eq('thinking part')
    end

    it 'supports thinking_block_complete attribute' do
      chunk = RubyLLM::Chunk.new(
        role: :assistant,
        content: 'partial',
        thinking_block_complete: true,
        complete_thinking_block: { 'type' => 'thinking', 'thinking' => 'full', 'signature' => 'sig123' }
      )

      expect(chunk.thinking_block_complete?).to be true
      expect(chunk.complete_thinking_block['signature']).to eq('sig123')
    end

    it 'thinking_block_complete? returns false by default' do
      chunk = RubyLLM::Chunk.new(role: :assistant, content: 'test')

      expect(chunk.thinking_block_complete?).to be false
    end
  end

  describe RubyLLM::StreamAccumulator do
    it 'accumulates thinking content across chunks' do
      accumulator = RubyLLM::StreamAccumulator.new

      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Hello ', thinking: 'First '))
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'world', thinking: 'second '))
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: '!', thinking: 'third'))

      expect(accumulator.thinking).to eq('First second third')
      expect(accumulator.content).to eq('Hello world!')
    end

    it 'handles chunks without thinking' do
      accumulator = RubyLLM::StreamAccumulator.new

      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Hello'))
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: ' world'))

      expect(accumulator.thinking).to eq('')
      expect(accumulator.content).to eq('Hello world')
    end

    it 'includes thinking in to_message when present' do
      accumulator = RubyLLM::StreamAccumulator.new
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Response', thinking: 'Reasoning'))

      message = accumulator.to_message(nil)

      expect(message.thinking).to eq('Reasoning')
    end

    it 'sets thinking to nil in to_message when empty' do
      accumulator = RubyLLM::StreamAccumulator.new
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Response'))

      message = accumulator.to_message(nil)

      expect(message.thinking).to be_nil
    end

    it 'stores complete thinking blocks with signatures' do
      accumulator = RubyLLM::StreamAccumulator.new
      complete_block = { 'type' => 'thinking', 'thinking' => 'Full reasoning', 'signature' => 'sig123' }

      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Hello', thinking: 'Full'))
      accumulator.add(RubyLLM::Chunk.new(
                        role: :assistant,
                        content: '',
                        thinking_block_complete: true,
                        complete_thinking_block: complete_block
                      ))

      expect(accumulator.thinking_blocks).to eq([complete_block])
    end

    it 'returns complete thinking blocks array in to_message when available' do
      accumulator = RubyLLM::StreamAccumulator.new
      complete_block = { 'type' => 'thinking', 'thinking' => 'Full reasoning', 'signature' => 'sig123' }

      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Response', thinking: 'Full'))
      accumulator.add(RubyLLM::Chunk.new(
                        role: :assistant,
                        content: '',
                        thinking_block_complete: true,
                        complete_thinking_block: complete_block
                      ))

      message = accumulator.to_message(nil)

      expect(message.thinking).to be_an(Array)
      expect(message.thinking.first['signature']).to eq('sig123')
    end

    it 'falls back to string thinking when no complete blocks' do
      accumulator = RubyLLM::StreamAccumulator.new

      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'Hello', thinking: 'First '))
      accumulator.add(RubyLLM::Chunk.new(role: :assistant, content: 'world', thinking: 'second'))

      message = accumulator.to_message(nil)

      expect(message.thinking).to eq('First second')
      expect(message.thinking).to be_a(String)
    end

    it 'accumulates multiple complete thinking blocks' do
      accumulator = RubyLLM::StreamAccumulator.new
      block1 = { 'type' => 'thinking', 'thinking' => 'First block', 'signature' => 'sig1' }
      block2 = { 'type' => 'thinking', 'thinking' => 'Second block', 'signature' => 'sig2' }

      accumulator.add(RubyLLM::Chunk.new(
                        role: :assistant,
                        content: '',
                        thinking_block_complete: true,
                        complete_thinking_block: block1
                      ))
      accumulator.add(RubyLLM::Chunk.new(
                        role: :assistant,
                        content: '',
                        thinking_block_complete: true,
                        complete_thinking_block: block2
                      ))

      expect(accumulator.thinking_blocks.length).to eq(2)
      expect(accumulator.thinking_blocks[0]['signature']).to eq('sig1')
      expect(accumulator.thinking_blocks[1]['signature']).to eq('sig2')
    end
  end

  describe RubyLLM::Chat do
    it 'supports with_params for reasoning_effort' do
      chat = RubyLLM.chat(model: 'gpt-4.1-nano', provider: :openai)
      chat.with_params(reasoning_effort: 'medium')

      expect(chat.params[:reasoning_effort]).to eq('medium')
    end

    it 'can chain with_params with other methods' do
      chat = RubyLLM.chat(model: 'gpt-4.1-nano', provider: :openai)
             .with_temperature(0.5)
             .with_params(reasoning_effort: 'high')

      expect(chat.params[:reasoning_effort]).to eq('high')
    end

    describe 'thinking callbacks' do
      it 'supports on_thinking callback registration' do
        chat = RubyLLM.chat(model: 'gpt-4.1-nano', provider: :openai)
        result = chat.on_thinking { |text| puts text }

        expect(result).to eq(chat) # Returns self for chaining
      end

      it 'supports on_thinking_complete callback registration' do
        chat = RubyLLM.chat(model: 'gpt-4.1-nano', provider: :openai)
        result = chat.on_thinking_complete { |block| puts block }

        expect(result).to eq(chat) # Returns self for chaining
      end

      it 'chains thinking callbacks with other methods' do
        chat = RubyLLM.chat(model: 'gpt-4.1-nano', provider: :openai)
               .with_temperature(0.5)
               .on_thinking { |text| text }
               .on_thinking_complete { |block| block }
               .with_params(thinking: { type: 'enabled', budget_tokens: 5000 })

        expect(chat.params[:thinking]).to eq({ type: 'enabled', budget_tokens: 5000 })
      end
    end
  end

  describe 'Provider implementations' do
    describe 'Anthropic' do
      describe '.extract_thinking_content' do
        it 'extracts thinking blocks as raw array (preserves signature)' do
          blocks = [
            { 'type' => 'thinking', 'thinking' => 'Let me reason...', 'signature' => 'sig123' },
            { 'type' => 'text', 'text' => 'The answer is 4' }
          ]

          thinking = RubyLLM::Providers::Anthropic::Chat.extract_thinking_content(blocks)

          expect(thinking).to be_an(Array)
          expect(thinking.length).to eq(1)
          expect(thinking.first['type']).to eq('thinking')
          expect(thinking.first['thinking']).to eq('Let me reason...')
          expect(thinking.first['signature']).to eq('sig123')
        end

        it 'handles redacted_thinking blocks' do
          blocks = [
            { 'type' => 'redacted_thinking', 'thinking' => 'Redacted content' },
            { 'type' => 'text', 'text' => 'Response' }
          ]

          thinking = RubyLLM::Providers::Anthropic::Chat.extract_thinking_content(blocks)

          expect(thinking).to be_an(Array)
          expect(thinking.first['type']).to eq('redacted_thinking')
        end

        it 'handles missing thinking blocks' do
          blocks = [
            { 'type' => 'text', 'text' => 'The answer is 4' }
          ]

          thinking = RubyLLM::Providers::Anthropic::Chat.extract_thinking_content(blocks)

          expect(thinking).to be_nil
        end
      end

      describe '.extract_thinking (streaming)' do
        it 'extracts thinking from streaming delta' do
          data = {
            'delta' => { 'type' => 'thinking_delta', 'thinking' => 'Thinking chunk' }
          }

          thinking = RubyLLM::Providers::Anthropic::Models.extract_thinking(data)

          expect(thinking).to eq('Thinking chunk')
        end

        it 'handles redacted_thinking in content_block' do
          data = {
            'content_block' => { 'type' => 'redacted_thinking', 'thinking' => 'Redacted' }
          }

          thinking = RubyLLM::Providers::Anthropic::Models.extract_thinking(data)

          expect(thinking).to eq('Redacted')
        end
      end

      describe 'thinking block tracking (streaming)' do
        let(:provider) { RubyLLM::Providers::Anthropic.new(RubyLLM.config) }

        before do
          # Reset tracking state before each test
          provider.send(:reset_thinking_block_tracking)
        end

        it 'tracks thinking blocks through their full lifecycle' do
          # Simulate the streaming events in order
          provider.send(:build_chunk, { 'type' => 'message_start' })

          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'thinking', 'thinking' => '' }
                        })

          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'Let me think ' }
                        })

          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'about this...' }
                        })

          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'signature_delta', 'signature' => 'sig123' }
                        })

          stop_chunk = provider.send(:build_chunk, {
                                       'type' => 'content_block_stop',
                                       'index' => 0
                                     })

          expect(stop_chunk.thinking_block_complete?).to be true
          expect(stop_chunk.complete_thinking_block['type']).to eq('thinking')
          expect(stop_chunk.complete_thinking_block['thinking']).to eq('Let me think about this...')
          expect(stop_chunk.complete_thinking_block['signature']).to eq('sig123')
        end

        it 'captures signature from content_block_stop event if present' do
          provider.send(:build_chunk, { 'type' => 'message_start' })

          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'thinking', 'thinking' => '' }
                        })

          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'My reasoning' }
                        })

          # Signature in stop event (newer API format)
          stop_chunk = provider.send(:build_chunk, {
                                       'type' => 'content_block_stop',
                                       'index' => 0,
                                       'content_block' => { 'signature' => 'stop_sig456' }
                                     })

          expect(stop_chunk.thinking_block_complete?).to be true
          expect(stop_chunk.complete_thinking_block['signature']).to eq('stop_sig456')
        end

        it 'tracks redacted_thinking blocks' do
          provider.send(:build_chunk, { 'type' => 'message_start' })

          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'redacted_thinking' }
                        })

          stop_chunk = provider.send(:build_chunk, {
                                       'type' => 'content_block_stop',
                                       'index' => 0
                                     })

          expect(stop_chunk.thinking_block_complete?).to be true
          expect(stop_chunk.complete_thinking_block['type']).to eq('redacted_thinking')
        end

        it 'returns false for non-thinking content_block_stop events' do
          provider.send(:build_chunk, { 'type' => 'message_start' })

          # Text block, not thinking
          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'text', 'text' => '' }
                        })

          stop_chunk = provider.send(:build_chunk, {
                                       'type' => 'content_block_stop',
                                       'index' => 0
                                     })

          expect(stop_chunk.thinking_block_complete?).to be false
          expect(stop_chunk.complete_thinking_block).to be_nil
        end

        it 'returns false for delta events' do
          provider.send(:build_chunk, { 'type' => 'message_start' })

          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'thinking', 'thinking' => '' }
                        })

          delta_chunk = provider.send(:build_chunk, {
                                        'type' => 'content_block_delta',
                                        'index' => 0,
                                        'delta' => { 'type' => 'thinking_delta', 'thinking' => 'partial' }
                                      })

          expect(delta_chunk.thinking_block_complete?).to be false
          expect(delta_chunk.complete_thinking_block).to be_nil
          expect(delta_chunk.thinking).to eq('partial')
        end

        it 'resets tracking state on message_start' do
          # First message
          provider.send(:build_chunk, { 'type' => 'message_start' })
          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'thinking', 'thinking' => '' }
                        })
          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'First message thinking' }
                        })

          # New message starts - should reset
          provider.send(:build_chunk, { 'type' => 'message_start' })
          provider.send(:build_chunk, {
                          'type' => 'content_block_start',
                          'index' => 0,
                          'content_block' => { 'type' => 'thinking', 'thinking' => '' }
                        })
          provider.send(:build_chunk, {
                          'type' => 'content_block_delta',
                          'index' => 0,
                          'delta' => { 'type' => 'thinking_delta', 'thinking' => 'Second message' }
                        })

          stop_chunk = provider.send(:build_chunk, {
                                       'type' => 'content_block_stop',
                                       'index' => 0
                                     })

          # Should only have second message's thinking
          expect(stop_chunk.complete_thinking_block['thinking']).to eq('Second message')
        end
      end

      describe 'Extended thinking with tool use' do
        let(:thinking_blocks) do
          [
            { 'type' => 'thinking', 'thinking' => 'Let me use a tool...', 'signature' => 'sig456' }
          ]
        end

        let(:tool_calls) do
          {
            'tool_123' => RubyLLM::ToolCall.new(
              id: 'tool_123',
              name: 'get_weather',
              arguments: { 'location' => 'Tokyo' }
            )
          }
        end

        it 'includes thinking blocks in formatted tool call message' do
          message = RubyLLM::Message.new(
            role: :assistant,
            content: '',
            thinking: thinking_blocks,
            tool_calls: tool_calls
          )

          formatted = RubyLLM::Providers::Anthropic::Tools.format_tool_call(message)

          expect(formatted[:role]).to eq('assistant')
          expect(formatted[:content].first).to eq(thinking_blocks.first)
          expect(formatted[:content].last[:type]).to eq('tool_use')
        end

        it 'preserves signature in thinking blocks' do
          message = RubyLLM::Message.new(
            role: :assistant,
            content: '',
            thinking: thinking_blocks,
            tool_calls: tool_calls
          )

          formatted = RubyLLM::Providers::Anthropic::Tools.format_tool_call(message)
          thinking_block = formatted[:content].first

          expect(thinking_block['signature']).to eq('sig456')
        end

        it 'handles legacy string thinking (backwards compatibility)' do
          message = RubyLLM::Message.new(
            role: :assistant,
            content: '',
            thinking: 'Legacy string thinking',
            tool_calls: tool_calls
          )

          formatted = RubyLLM::Providers::Anthropic::Tools.format_tool_call(message)
          thinking_block = formatted[:content].first

          expect(thinking_block[:type]).to eq('thinking')
          expect(thinking_block[:thinking]).to eq('Legacy string thinking')
        end

        it 'handles nil thinking' do
          message = RubyLLM::Message.new(
            role: :assistant,
            content: 'Some text',
            thinking: nil,
            tool_calls: tool_calls
          )

          formatted = RubyLLM::Providers::Anthropic::Tools.format_tool_call(message)

          # Should not have a thinking block, just text and tool_use
          expect(formatted[:content].first[:type]).to eq('text')
          expect(formatted[:content].last[:type]).to eq('tool_use')
        end

        it 'handles empty string thinking' do
          message = RubyLLM::Message.new(
            role: :assistant,
            content: 'Some text',
            thinking: '',
            tool_calls: tool_calls
          )

          formatted = RubyLLM::Providers::Anthropic::Tools.format_tool_call(message)

          # Should not have a thinking block
          expect(formatted[:content].none? { |b| b[:type] == 'thinking' || b['type'] == 'thinking' }).to be true
        end
      end
    end

    describe 'Gemini' do
      let(:provider) { RubyLLM::Providers::Gemini.new(RubyLLM.config) }

      it 'extracts thinking from thought parts' do
        data = {
          'candidates' => [{
            'content' => {
              'parts' => [
                { 'thought' => true, 'text' => 'My reasoning process' },
                { 'text' => 'The final answer' }
              ]
            }
          }]
        }

        thinking = provider.send(:extract_thinking_content, data)

        expect(thinking).to eq('My reasoning process')
      end

      it 'handles parts without thoughts' do
        data = {
          'candidates' => [{
            'content' => {
              'parts' => [
                { 'text' => 'Just regular content' }
              ]
            }
          }]
        }

        thinking = provider.send(:extract_thinking_content, data)

        expect(thinking).to be_nil
      end
    end
  end
end
