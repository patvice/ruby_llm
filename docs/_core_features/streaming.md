---
layout: default
title: Stream Responses
nav_order: 3
description: Learn how to display AI responses in real-time as they're generated
redirect_from:
  - /guides/streaming
---

# {{ page.title }}
{: .no_toc }

{{ page.description }}
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

After reading this guide, you will know:

*   How to initiate a streaming chat request.
*   How to process the streamed `Chunk` objects.
*   How the final accumulated message is handled.
*   How to integrate streaming with web frameworks like Rails and Sinatra.
*   How streaming interacts with Tools.
*   How to capture reasoning/thinking output from supported models.
*   How to use thinking callbacks for real-time display and persistence.

## Basic Streaming

To stream responses, simply provide a block to the `ask` method on a `Chat` object.

```ruby
chat = RubyLLM.chat

puts "Assistant:"
chat.ask "Write a short story about a adventurous ruby gem." do |chunk|
  # The block receives RubyLLM::Chunk objects as they arrive
  print chunk.content # Print content fragment immediately
end
# => (Output appears incrementally) Once upon a time, in the vast digital...
```

RubyLLM normalizes different provider streaming formats (like Server-Sent Events) into standardized `Chunk` objects.

## Understanding Chunks

Each object yielded to the block is an instance of `RubyLLM::Chunk`, which inherits from `RubyLLM::Message`. It contains the partial information received in that specific part of the stream.

Key attributes of a `Chunk`:

*   `chunk.content`: The text fragment received in this chunk (can be `nil` or empty for some chunks, especially those containing only metadata or tool calls).
*   `chunk.role`: Always `:assistant` for streamed response chunks.
*   `chunk.model_id`: The model generating the response (usually present).
*   `chunk.tool_calls`: A hash containing partial or complete tool call information if the model is invoking a [Tool]({% link _core_features/tools.md %}). The arguments might be streamed incrementally.
*   `chunk.thinking`: The reasoning/thinking content from models that support extended thinking (see [Streaming with Reasoning Models](#streaming-with-reasoning-models)).
*   `chunk.input_tokens`: Total input tokens for the request (often `nil` until the final chunk).
*   `chunk.output_tokens`: Cumulative output tokens *up to this chunk* (behavior varies by provider, often only accurate in the final chunk).

> Do not rely on token counts being present or accurate in every chunk. They are typically finalized only in the last chunk or the final returned message.
{: .warning }

## Accumulated Response

Even when you provide a block for streaming, the `ask` method *still* returns the complete, final `RubyLLM::Message` object once the entire response (including any tool interactions) is finished.

```ruby
chat = RubyLLM.chat
final_message = nil

puts "Assistant:"
final_message = chat.ask "Write a short haiku about programming." do |chunk|
  print chunk.content
end

# The block finishes, and ask returns the complete message
puts "\n--- Final Message ---"
puts final_message.content
# => Code flows like water,
# => Logic builds a new world now,
# => Bugs swim in the stream.

puts "Total Tokens: #{(final_message.input_tokens || 0) + (final_message.output_tokens || 0)}"
```

This allows you to easily get the final result for storage or further processing, even after handling the stream for UI purposes.

## Web Application Integration

Streaming is particularly useful in web applications for providing immediate feedback.

### Rails with Turbo Streams

In a Rails application using Hotwire/Turbo, you can broadcast stream updates from a background job.

```ruby
# app/jobs/chat_stream_job.rb
class ChatStreamJob < ApplicationJob
  queue_as :default

  def perform(chat_id, user_message, stream_target_id)
    chat = Chat.find(chat_id) # Assuming acts_as_chat model
    full_response = ""

    # Broadcast an initial placeholder
    Turbo::StreamsChannel.broadcast_replace_to(
      "chat_#{chat.id}",
      target: stream_target_id,
      partial: "messages/streaming_message",
      locals: { content: "Thinking..." }
    )

    chat.ask(user_message) do |chunk|
      full_response << (chunk.content || "")
      # Broadcast updates, replacing the placeholder content
      Turbo::StreamsChannel.broadcast_replace_to(
        "chat_#{chat.id}",
        target: stream_target_id,
        partial: "messages/streaming_message",
        locals: { content: full_response } # Send accumulated content
      )
    end

    # Optionally broadcast a final state or confirmation
  end
end

# app/views/messages/_streaming_message.html.erb
# <div id="<%= stream_target_id %>">
#   <%= simple_format(content) %>
# </div>

# In your controller:
# target_id = "stream_#{SecureRandom.uuid}"
# Render initial UI with <div id="<%= target_id %>"></div>
# ChatStreamJob.perform_later(chat.id, params[:message], target_id)
```

See the [Rails Integration Guide]({% link _advanced/rails.md %}#streaming-responses-with-hotwireturbo) for more detailed examples.

### Sinatra with Server-Sent Events (SSE)

SSE is a natural fit for streaming text responses.

```ruby
require 'sinatra'
require 'ruby_llm'
# ... configuration ...

get '/stream_chat' do
  content_type 'text/event-stream'
  stream(:keep_open) do |out|
    chat = RubyLLM.chat
    begin
      chat.ask(params[:prompt] || "Tell me a fun fact.") do |chunk|
        # Send each content chunk as an SSE data event
        out << "data: #{chunk.content.to_json}\n\n" if chunk.content
      end
      # Signal completion
      out << "event: complete\ndata: {}\n\n"
    rescue => e
      # Signal error
      out << "event: error\ndata: #{ { error: e.message }.to_json }\n\n"
    ensure
      out.close
    end
  end
end
```

## Error Handling During Streaming

Errors (like network issues, rate limits, or provider errors) can occur mid-stream. The `ask` method will raise the appropriate `RubyLLM::Error` subclass after the block execution finishes or is interrupted by the error.

```ruby
begin
  chat = RubyLLM.chat
  puts "Assistant:"
  chat.ask("Generate a very long response...") do |chunk|
    print chunk.content
    # Potential error occurs here
  end
rescue RubyLLM::Error => e
  puts "\n--- Error during streaming ---"
  puts "Error Type: #{e.class}"
  puts "Message: #{e.message}"
  # Check e.response for more details if needed
end
```

Refer to the [Error Handling Guide]({% link _advanced/error-handling.md %}) for details on specific error types.

## Streaming with Tools

When a chat interaction involves [Tools]({% link _core_features/tools.md %}), the streaming behavior has distinct phases:

1.  **Initial Response Stream:** Chunks are yielded as the model generates text *up to* the point where it decides to call a tool.
2.  **Tool Call Chunk(s):** One or more chunks containing `chunk.tool_calls` information are yielded. The arguments might be streamed incrementally depending on the provider.
3.  **Pause:** Streaming pauses while RubyLLM executes your tool's `execute` method.
4.  **Resumed Response Stream:** After the tool result is sent back to the model, streaming resumes, yielding chunks containing the model's final response incorporating the tool's output.

```ruby
chat = RubyLLM.chat(model: '{{ site.models.openai_tools }}').with_tool(Weather) # Assumes Weather tool is defined

puts "Assistant:"
chat.ask("What's the weather in Berlin (52.52, 13.40)?") do |chunk|
  if chunk.tool_calls
    puts "\n[TOOL CALL DETECTED: #{chunk.tool_calls.values.first.name}]"
    # Arguments might be partial here: chunk.tool_calls.values.first.arguments
  elsif chunk.content
    print chunk.content
  end
end
# Output might look like:
# Assistant:
# Okay, let me check the weather for Berlin.
# [TOOL CALL DETECTED: weather] # Pause while tool executes
# The current weather in Berlin (52.52, 13.4) is 15°C with wind at 10 km/h.
```

Your streaming block needs to be prepared to handle chunks that contain text content, tool call information, or potentially just metadata.

## Streaming with Reasoning Models
{: .d-inline-block }

New
{: .label .label-green }

Some AI models support "extended thinking" or "reasoning" capabilities, where the model shows its internal thought process before providing a final answer. RubyLLM captures this thinking content separately from the main response.

### Supported Providers

RubyLLM extracts thinking/reasoning output from providers that expose it in their API responses:

| Provider | Models | API Field |
|----------|--------|-----------|
| **Anthropic** | Claude 3.7 Sonnet, Claude 4 | `thinking` blocks |
| **Bedrock** | Claude 3.7 Sonnet (via AWS) | `thinking` blocks |
| **Gemini** | `gemini-2.0-flash-thinking-exp` | `thought` parts |
| **VertexAI** | Same as Gemini (via Google Cloud) | `thought` parts |
| **DeepSeek** | `deepseek-reasoner` (R1) | `reasoning_content` |
| **GPUStack** | Qwen3, other reasoning models | `reasoning_content` |
| **Ollama** | Qwen3, DeepSeek R1 variants | `reasoning_content` |
| **Mistral** | Magistral models | `reasoning_content` |
| **Perplexity** | `sonar-reasoning`, `sonar-reasoning-pro` | `reasoning_content` |
| **OpenRouter** | Any model with reasoning support | `reasoning_content` |

> **OpenAI's o1/o3/o4 models** do **not** expose their internal reasoning. Their thinking tokens are counted for billing but the content is discarded before the response is returned. This is by design.
{: .note }

### Enabling Extended Thinking

Each provider has different ways to enable or access reasoning output:

```ruby
# Anthropic/Bedrock - enable extended thinking with a token budget
chat = RubyLLM.chat(model: 'claude-sonnet-4-20250514')
chat.with_params(
  thinking: { type: "enabled", budget_tokens: 2000 },
  max_tokens: 16000
)

# Gemini/VertexAI - use a thinking model variant
chat = RubyLLM.chat(model: 'gemini-2.0-flash-thinking-exp')

# DeepSeek - use the reasoner model (thinking is automatic)
chat = RubyLLM.chat(model: 'deepseek-reasoner')

# GPUStack/Ollama - use a reasoning-capable model like Qwen3
# Thinking is returned automatically when the model supports it
chat = RubyLLM.chat(model: 'qwen3')
```

For models that use `reasoning_content` (DeepSeek, GPUStack, Ollama, etc.), the thinking is returned automatically—no special parameters needed.

### Handling Thinking in Streams

When streaming, thinking content arrives in `chunk.thinking` separately from the main `chunk.content`. This works the same way across all providers:

```ruby
# Works with any reasoning-capable model:
# - Anthropic: claude-sonnet-4-20250514 (with thinking params)
# - DeepSeek: deepseek-reasoner
# - GPUStack/Ollama: qwen3
# - Gemini: gemini-2.0-flash-thinking-exp

chat = RubyLLM.chat(model: 'deepseek-reasoner')

response = chat.ask("What is 15 * 17? Think step by step.") do |chunk|
  # Display thinking content (often shown in a collapsible UI element)
  if chunk.thinking
    print "[THINKING] #{chunk.thinking}"
  end

  # Display regular response content
  if chunk.content
    print chunk.content
  end
end

# The final message also contains the complete thinking
puts "\n--- Final Response ---"
puts "Thinking: #{response.thinking}"
puts "Answer: #{response.content}"
```

### Thinking Callbacks

RubyLLM provides dedicated callbacks for handling thinking content during streaming:

```ruby
chat = RubyLLM.chat(model: 'claude-sonnet-4-20250514')
  .with_params(thinking: { type: 'enabled', budget_tokens: 5000 })

# Called for each streaming delta (partial thinking text)
chat.on_thinking do |thinking_text|
  print thinking_text
end

# Called when a complete thinking block is received (with signature)
chat.on_thinking_complete do |thinking_block|
  # thinking_block is a hash: { 'type' => 'thinking', 'thinking' => '...', 'signature' => '...' }
  save_thinking_to_database(thinking_block)
end

chat.ask("What is 15 * 17?") do |chunk|
  print chunk.content
end
```

The `on_thinking_complete` callback is particularly useful for Anthropic's extended thinking, which requires complete thinking blocks (including signatures) to be preserved for multi-turn conversations with tools.

### UI Integration Example

In a web application, you might display thinking content differently from the main response:

```ruby
# Rails controller with Turbo Streams
chat.ask(user_message) do |chunk|
  if chunk.thinking
    # Update a collapsible "Show reasoning" section
    Turbo::StreamsChannel.broadcast_append_to(
      "chat_#{chat_id}",
      target: "thinking_content",
      html: chunk.thinking
    )
  elsif chunk.content
    # Update the main response area
    Turbo::StreamsChannel.broadcast_append_to(
      "chat_#{chat_id}",
      target: "response_content",
      html: chunk.content
    )
  end
end
```

### Rails Persistence

If you're using the [Rails Integration]({% link _advanced/rails.md %}), the `thinking` attribute is automatically persisted when you run the upgrade generator:

```bash
rails generate ruby_llm:upgrade_to_v2_0
rails db:migrate
```

This adds a `thinking` column to your messages table, and thinking content will be saved alongside regular message content.

## Next Steps

*   [Using Tools]({% link _core_features/tools.md %})
*   [Rails Integration]({% link _advanced/rails.md %})
*   [Error Handling]({% link _advanced/error-handling.md %})
